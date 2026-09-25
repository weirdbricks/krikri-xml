require "./nodes"

module KXML
  # Decodes the UTF-8 character at byte position *pos* in *s* and returns
  # it with its byte length. String#char_at indexes by character, which is
  # wrong for a byte-driven scanner. Reads go through unsafe_byte_at with
  # an explicit length guard (cheaper than checked byte_at on the hot path),
  # and malformed sequences raise KXML::Error instead of letting the raw
  # codepoint escape as a foreign exception.
  def self.decode_char_at(s : String, pos : Int) : {Char, Int32}
    b0 = s.to_unsafe[pos].to_i
    if b0 < 0x80
      {b0.chr, 1}
    else
      len = b0 >= 0xF0 ? 4 : (b0 >= 0xE0 ? 3 : 2)
      if pos + len > s.bytesize
        raise Error.new("invalid UTF-8 byte sequence", 1, pos, "document")
      end
      cp = if len == 2
             ((b0 & 0x1F) << 6) | (s.to_unsafe[pos + 1].to_i & 0x3F)
           elsif len == 3
             b1 = s.to_unsafe[pos + 1].to_i
             b2 = s.to_unsafe[pos + 2].to_i
             ((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F)
           else
             b1 = s.to_unsafe[pos + 1].to_i
             b2 = s.to_unsafe[pos + 2].to_i
             b3 = s.to_unsafe[pos + 3].to_i
             ((b0 & 0x07) << 18) | ((b1 & 0x3F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F)
           end
      if cp > 0x10FFFF || (0xD800 <= cp <= 0xDFFF)
        raise Error.new("invalid UTF-8 byte sequence", 1, pos, "document")
      end
      {cp.chr, len}
    end
  end

  # Strict, pure-Crystal XML 1.0 (Fifth Edition) parser.
  #
  # Implemented directly from W3C REC-xml-20081126 (well-formedness only,
  # no DTD validation). Raises `KXML::Error` on any well-formedness
  # violation, mirroring lxml's non-recovering behavior.
  class Parser
    # Element nesting is recursive (parse_element <-> parse_content), so the
    # limit must stay low enough that the guard raises KXML::Error before the
    # call stack overflows. Stack overflow testing shows nesting dies around
    # depth ~6,000 on an 8 MB stack; 2,048 (libxml2's XML_MAX_DEPTH) leaves a
    # wide safety margin across platforms.
    MAX_ELEMENT_DEPTH  =      2_048
    MAX_ENTITY_DEPTH   =         64
    MAX_EXPANDED_BYTES = 10_000_000

    # Predefined entities (4.6). Stored as their spec-required replacement
    # texts: char references to the respective character (double escaping
    # REQUIRED for lt/amp so references re-expand to data, never markup).
    PREDEFINED_ENTITIES = {
      "lt"   => "&#60;",
      "gt"   => "&#62;",
      "amp"  => "&#38;",
      "apos" => "&#39;",
      "quot" => "&#34;",
    }

    private struct Entity
      getter replacement : String
      getter? external : Bool
      getter? unparsed : Bool

      def initialize(@replacement : String, @external = false, @unparsed = false)
      end
    end

    private struct AttDef
      getter type : String
      getter default_raw : String?
      getter? fixed : Bool

      def initialize(@type : String, @default_raw : String?, @fixed : Bool)
      end
    end

    private struct Ref
      getter codepoint : Int32
      getter name : String?

      def initialize(@codepoint : Int32)
        @name = nil
      end

      def initialize(@name : String)
        @codepoint = -1
      end
    end

    private class Scanner
      @sources = [] of String
      @labels = [] of String
      @positions = [] of Int32

      @push_elem_depths = [] of Int32
      @popped_depths = [] of {Int32, Int32}
      property elem_depth_getter : Proc(Int32)? = nil

      # One-entry lookahead cache for peek/advance: (source index, byte
      # position, decoded char, byte length). Lets advance() prefetch the
      # next character so each char is decoded only once.
      @cache_src : Int32 = -1
      @cache_pos : Int32 = -1
      @cache_char : Char = '\0'
      @cache_len : Int32 = 1

      def initialize(source : String, label : String)
        push(source, label, -1)
      end

      def push(source : String, label : String, elem_depth : Int32) : Nil
        @cache_src = -1
        @sources << source
        @labels << label
        @positions << 0
        @push_elem_depths << elem_depth
      end

      # Element depth recorded when the current top source was pushed;
      # 0 for the base document.
      def top_push_elem_depth : Int32
        @push_elem_depths.last? || 0
      end

      # {recorded push depth, element depth at pop time} for
      # balance-tracked sources popped by compact; drained by the parser.
      def popped_depths : Array({Int32, Int32})
        @popped_depths
      end

      # Number of pushed (entity) sources above the base document.
      def depth : Int32
        @sources.size - 1
      end

      def label : String
        @labels.last
      end

      # Line/column are only needed when an error is raised, so they are
      # computed lazily by scanning the current source up to the position.
      def line : Int32
        1 + _newlines_before(@positions.last)
      end

      def column : Int32
        src = @sources.last
        pos = @positions.last
        line_start = src.rindex('\n', pos - 1)
        line_start ? pos - line_start - 1 : pos + 1
      end

      private def _newlines_before(pos : Int32) : Int32
        src = @sources.last
        count = 0
        src[0, pos].each_char { |char| count += 1 if char == '\n' }
        count
      end

      private def compact : Nil
        while @sources.size > 1 && @positions.last >= @sources.last.bytesize
          @cache_src = -1
          @sources.pop
          @labels.pop
          @positions.pop
          d = @push_elem_depths.pop
          if d >= 0
            cur = @elem_depth_getter.try(&.call) || 0
            @popped_depths << {d, cur}
          end
        end
      end

      def eof? : Bool
        compact
        @sources.size == 1 && @positions.last >= @sources.last.bytesize
      end

      # True when only the base document source is on the stack (no
      # entity expansion in progress); enables byte-level fast paths.
      def single_source? : Bool
        @sources.size == 1
      end

      # Byte-level whitespace skip for the common single-source case.
      # Returns true if at least one whitespace char was consumed.
      def skip_ascii_whitespace : Bool
        return false unless @sources.size == 1
        src = @sources[0]
        pos = @positions[0]
        bytes = src.bytesize
        start = pos
        while pos < bytes
          b = src.byte_at(pos)
          if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
            pos += 1
          else
            break
          end
        end
        if pos > start
          @positions[0] = pos
          true
        else
          false
        end
      end

      # Byte-level name read for the common single-source ASCII case.
      # Returns nil when not applicable; consumes at least one char when
      # a name is returned.
      def read_ascii_name : String?
        return unless @sources.size == 1
        src = @sources[0]
        pos = @positions[0]
        bytes = src.bytesize
        start = pos
        while pos < bytes
          b = src.byte_at(pos)
          if (0x41 <= b <= 0x5A) || (0x61 <= b <= 0x7A) || (0x30 <= b <= 0x39) ||
             b == 0x2D || b == 0x2E || b == 0x3A || b == 0x5F
            pos += 1
          else
            break
          end
        end
        return if pos == start
        # If the run ends right before a non-ASCII byte, that byte may be
        # a Unicode name character - fall back to the slow path.
        return if pos < bytes && src.byte_at(pos) >= 0x80
        @positions[0] = pos
        # The scanned run is pure ASCII, so build the string from raw bytes
        # (String#[] indexes by character, not byte, and converting byte
        # offsets would be O(n) per name).
        String.new(Slice.new(src.to_unsafe + start, pos - start))
      end

      # Batch-scans plain character data (single-source case only): bytes
      # until '<', '&' or a "]]>" sequence. Returns nil when entity
      # sources are active (caller falls back to the per-char loop). The
      # '>' of a "]]>" is left unconsumed so the caller's raw-tracking
      # check reports the error. *brackets* is the number of ']' already
      # pending from the previous chunk (0-2).
      def read_plain_text(brackets : Int32) : String?
        return unless @sources.size == 1
        src = @sources[0]
        pos = @positions[0]
        bytes = src.bytesize
        start = pos
        run = brackets
        while pos < bytes
          b = src.byte_at(pos)
          if b >= 0x20
            if b >= 0x80
              len = xml_char_len_at(src, pos)
              if len == 0
                # Not provably valid: rewind so the per-char path decodes
                # it and raises the precise error if it is indeed invalid.
                @positions[0] = start
                return
              end
              run = 0
              pos += len
            elsif b == 0x3C || b == 0x26 # '<' '&'
              break
            elsif b == 0x5D # ']'
              run = run >= 2 ? 2 : run + 1
              pos += 1
            elsif b == 0x3E && run >= 2 # '>' closing a "]]>"
              break
            else
              run = 0
              pos += 1
            end
          elsif b == 0x9 || b == 0xA # tab, LF
            run = 0
            pos += 1
          else
            # Control character: rewind, the per-char path raises.
            @positions[0] = start
            return
          end
        end
        return "" if pos == start
        @positions[0] = pos
        # The chunk ends at '<', '&' or before "]]>", never mid-character.
        String.new(Slice.new(src.to_unsafe + start, pos - start))
      end

      # Batch-scans attribute-value bytes (single-source case only) up
      # to the closing quote, '<' or '&'. Returns nil when entity sources
      # are active. Returns "" without consuming when already at one of
      # those stops.
      def read_attr_chunk(quote : Char) : String?
        return unless @sources.size == 1
        src = @sources[0]
        pos = @positions[0]
        bytes = src.bytesize
        start = pos
        qb = quote.ord
        while pos < bytes
          b = src.byte_at(pos)
          if b >= 0x20
            if b >= 0x80
              len = xml_char_len_at(src, pos)
              if len == 0
                @positions[0] = start
                return
              end
              pos += len
            else
              break if b == qb || b == 0x3C || b == 0x26 # quote '<' '&'
              pos += 1
            end
          elsif b == 0x9 || b == 0xA # tab, LF are valid attribute data
            pos += 1
          else
            @positions[0] = start
            return
          end
        end
        return "" if pos == start
        @positions[0] = pos
        String.new(Slice.new(src.to_unsafe + start, pos - start))
      end

      def peek : Char?
        return if eof?
        si = @sources.size - 1
        pos = @positions.last
        if @cache_src == si && @cache_pos == pos
          return @cache_char
        end
        ch, len = KXML.decode_char_at(@sources[si], pos)
        @cache_src = si
        @cache_pos = pos
        @cache_char = ch
        @cache_len = len
        ch
      end

      def advance : Char
        compact
        if @positions.last >= @sources.last.bytesize
          raise "scanner bug: advance at EOF"
        end
        si = @sources.size - 1
        pos = @positions.last
        ch, len = KXML.decode_char_at(@sources[si], pos)
        validate_char(ch)
        @positions[si] = pos + len
        # Prefetch disabled for bisection (re-measured: neutral on small
        # documents, ~10% slower on large ones)
        @cache_src = -1
        ch
      end

      # Character validation lives here instead of a separate O(n) pass over
      # the whole document: every character the parser consumes goes through
      # advance (or through the batch fast paths, which hand anything
      # questionable to this path via xml_char_len_at), so each character is
      # checked exactly once on the way in.
      private def validate_char(ch : Char) : Nil
        cp = ch.ord
        return if cp == 0x9 || cp == 0xA || cp == 0xD ||
                  (0x20 <= cp <= 0xD7FF) || (0xE000 <= cp <= 0xFFFD) ||
                  (0x10000 <= cp <= 0x10FFFF)
        raise KXML::Error.new("invalid XML character U+#{cp.to_s(16)}", line, column, label)
      end

      # Byte length of the UTF-8 sequence at byte *pos* in *src* when it
      # encodes a valid XML 1.0 character, or 0 when the byte must be left
      # to the validating per-char path (malformed UTF-8, control chars,
      # surrogates, noncharacters). Lets the batch fast paths run without
      # ever copying an unvalidated byte into the DOM.
      private def xml_char_len_at(src : String, pos : Int32) : Int32
        b0 = src.byte_at(pos)
        return 0 if b0 < 0x20 && b0 != 0x9 && b0 != 0xA && b0 != 0xD
        return 1 if b0 < 0x80
        bytes = src.bytesize
        if b0 < 0xC0
          0
        elsif b0 < 0xE0
          return 0 if pos + 1 >= bytes
          b1 = src.byte_at(pos + 1)
          return 0 unless b1 & 0xC0 == 0x80
          cp = ((b0 & 0x1F) << 6) | (b1 & 0x3F)
          cp >= 0x80 ? 2 : 0
        elsif b0 < 0xF0
          return 0 if pos + 2 >= bytes
          b1 = src.byte_at(pos + 1)
          b2 = src.byte_at(pos + 2)
          return 0 unless (b1 & 0xC0 == 0x80) && (b2 & 0xC0 == 0x80)
          cp = ((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F)
          return 0 if cp < 0x800 || (0xD800 <= cp <= 0xDFFF) || cp == 0xFFFE || cp == 0xFFFF
          3
        else
          return 0 if b0 > 0xF4 || pos + 3 >= bytes
          b1 = src.byte_at(pos + 1)
          b2 = src.byte_at(pos + 2)
          b3 = src.byte_at(pos + 3)
          return 0 unless (b1 & 0xC0 == 0x80) && (b2 & 0xC0 == 0x80) && (b3 & 0xC0 == 0x80)
          cp = ((b0 & 0x07) << 18) | ((b1 & 0x3F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F)
          return 0 if cp < 0x10000 || cp > 0x10FFFF
          4
        end
      end

      # Consume *str* if the next characters match it (possibly across
      # entity-source boundaries); otherwise restore the exact state.
      #
      # Invariant: *str* is always ASCII markup ("<?xml", "<![CDATA[", "-->",
      # ...), so the byte-compare fast path only ever consumes provably valid
      # XML characters.
      def match?(str : String) : Bool
        # Fast path: single source, pure-ASCII str, no entity expansion
        # active - compare bytes directly with no state duplication.
        if @sources.size == 1
          src = @sources[0]
          pos = @positions[0]
          bytes = src.bytesize
          ok = true
          i = 0
          while i < str.bytesize
            p = pos + i
            if p >= bytes || src.byte_at(p) != str.byte_at(i)
              ok = false
              break
            end
            i += 1
          end
          return false unless ok
          @positions[0] = pos + str.bytesize
          return true
        end
        saved_sources = @sources.dup
        saved_labels = @labels.dup
        saved_positions = @positions.dup
        ok = true
        str.each_char do |char|
          p = peek
          if p.nil? || p != char
            ok = false
            break
          end
          advance
        end
        unless ok
          @sources = saved_sources
          @labels = saved_labels
          @positions = saved_positions
        end
        ok
      end
    end

    @scanner : Scanner
    @bom_encoding : String? = nil
    @doc = Document.new
    @entities = {} of String => Entity
    @pes = {} of String => Entity
    @attlists = {} of String => Hash(String, AttDef)
    @dep_graph = {} of String => Set(String)
    @ns_stack = [] of Hash(String, String?)
    @element_depth = 0
    @order_counter = 0
    @expanded_bytes = 0
    @text_buf : String::Builder? = nil
    @text_buf_order : Int32? = nil
    # Pending text as a raw string; only promoted into @text_buf when a
    # character/entity reference forces incremental building.
    @pending_text : String? = nil
    @raw_pp : Char? = nil
    @raw_prev : Char? = nil
    @raw_label : String? = nil
    @has_parameter_entity = false
    @raw_pp : Char? = nil
    @raw_prev : Char? = nil
    @raw_label : String? = nil

    def initialize(source : String)
      @scanner = Scanner.new(source, "document")
      @scanner.elem_depth_getter = -> { @element_depth }
      base = Hash(String, String?).new
      base["xml"] = XML_NAMESPACE_URI
      @ns_stack << base
    end

    def self.parse(source : String) : Document
      new(normalize_eol(source)).parse
    end

    # 2.11: #xD#xA and any lone #xD become #xA on input, before parsing.
    # Single pass; the gsub pair this replaces allocated two intermediates.
    def self.normalize_eol(source : String) : String
      return source unless source.includes?('\r')
      String.build(source.bytesize) do |builder|
        pos = 0
        bytes = source.bytesize
        while pos < bytes
          b = source.byte_at(pos)
          if b == 0x0D
            builder << '\n'
            pos += (pos + 1 < bytes && source.byte_at(pos + 1) == 0x0A) ? 2 : 1
          else
            builder.write_byte(b)
            pos += 1
          end
        end
      end
    end

    def self.valid_codepoint?(cp : Int32) : Bool
      cp == 0x9 || cp == 0xA || cp == 0xD ||
        (0x20 <= cp <= 0xD7FF) ||
        (0xE000 <= cp <= 0xFFFD) ||
        (0x10000 <= cp <= 0x10FFFF)
    end

    # ------------------------------------------------------------------
    # errors

    private def next_order : Int32
      @order_counter += 1
    end

    private def error(message : String) : NoReturn
      raise Error.new(message, @scanner.line, @scanner.column, @scanner.label)
    end

    # ------------------------------------------------------------------
    # lexical helpers

    private def ascii_hex_digit?(ch : Char) : Bool
      ('0' <= ch <= '9') || ('a' <= ch <= 'f') || ('A' <= ch <= 'F')
    end

    private def name_start_char?(ch : Char) : Bool
      return true if ch == ':'
      return true if 'A' <= ch <= 'Z'
      return true if ch == '_'
      return true if 'a' <= ch <= 'z'
      cp = ch.ord
      (0xC0..0xD6).includes?(cp) || (0xD8..0xF6).includes?(cp) ||
        (0xF8..0x2FF).includes?(cp) || (0x370..0x37D).includes?(cp) ||
        (0x37F..0x1FFF).includes?(cp) || (0x200C..0x200D).includes?(cp) ||
        (0x2070..0x218F).includes?(cp) || (0x2C00..0x2FEF).includes?(cp) ||
        (0x3001..0xD7FF).includes?(cp) || (0xF900..0xFDCF).includes?(cp) ||
        (0xFDF0..0xFFFD).includes?(cp) || (0x10000..0xEFFFF).includes?(cp)
    end

    private def name_char?(ch : Char) : Bool
      return true if name_start_char?(ch)
      return true if ch == '-' || ch == '.'
      return true if '0' <= ch <= '9'
      cp = ch.ord
      cp == 0xB7 || (0x300..0x36F).includes?(cp) || (0x203F..0x2040).includes?(cp)
    end

    private def whitespace?(ch : Char) : Bool
      ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r'
    end

    private def skip_s : Bool
      return true if @scanner.skip_ascii_whitespace
      found = false
      while c = @scanner.peek
        break unless whitespace?(c)
        @scanner.advance
        found = true
      end
      found
    end

    private def require_s(context : String) : Nil
      c = @scanner.peek
      error("expected whitespace #{context}") unless c && whitespace?(c)
      skip_s
    end

    private def expect(ch : Char, what : String) : Nil
      c = @scanner.peek
      error("expected #{what}") unless c == ch
      @scanner.advance
    end

    private def parse_name_raw : String
      c = @scanner.peek
      error("expected a name") if c.nil? || !name_start_char?(c)
      if (c.ascii_letter? || c == '_') && (s = @scanner.read_ascii_name)
        return s
      end
      String.build do |b|
        b << @scanner.advance
        while d = @scanner.peek
          break unless name_char?(d)
          b << @scanner.advance
        end
      end
    end

    private def split_qname(raw : String) : {String?, String}
      colon = raw.index(':')
      return {nil, raw} unless colon
      error("invalid name '#{raw}'") if raw.index(':', colon + 1)
      prefix = raw[0...colon]
      local = raw[(colon + 1)..]
      error("invalid name '#{raw}'") if prefix.empty? || local.empty?
      {prefix, local}
    end

    # Parses '#'... ';' (the '#' already consumed) and validates the
    # codepoint against production [2] Char. *ref_depth* is the scanner
    # depth at the '&' so a reference cannot span entity boundaries.
    private def parse_char_ref_after_hash(ref_depth : Int32) : Int32
      hex = false
      if x = @scanner.peek
        if x == 'x'
          @scanner.advance
          hex = true
        end
      end
      digits = String::Builder.new
      while d = @scanner.peek
        ok = hex ? ascii_hex_digit?(d) : d.ascii_number?
        break unless ok
        digits << @scanner.advance
      end
      digs = digits.to_s
      error("character reference contains no digits") if digs.empty?
      error("entity references must not span entity boundaries") if @scanner.depth != ref_depth
      error("unterminated character reference (expected ';')") unless @scanner.peek == ';'
      @scanner.advance
      cp = digs.to_i(hex ? 16 : 10)
      error("character reference out of range") if cp > 0x10FFFF
      error("character reference to an invalid XML character") unless Parser.valid_codepoint?(cp)
      cp
    end

    # Parses Name ';' (the '&' already consumed). *ref_depth* is the
    # scanner depth at the '&' so a reference cannot span entity boundaries.
    private def parse_entity_ref_name(ref_depth : Int32) : String
      name = parse_name_raw
      error("entity references must not span entity boundaries") if @scanner.depth != ref_depth
      error("unterminated entity reference (expected ';')") unless @scanner.peek == ';'
      @scanner.advance
      name
    end

    # ------------------------------------------------------------------
    # entry point

    def parse : Document
      skip_bom
      parse_prolog
      root = parse_element
      root.parent_node = @doc
      @doc.root = root
      parse_epilog
      @doc
    end

    private def skip_bom : Nil
      if (c = @scanner.peek) && c.ord == 0xFEFF
        @bom_encoding = "utf-8"
        @scanner.advance
      end
    end

    private def parse_prolog : Nil
      prolog_started = false
      loop do
        prolog_started = true if skip_s
        c = @scanner.peek
        error("no root element found") if c.nil?
        if c == '<'
          if !prolog_started && @scanner.match?("<?xml")
            parse_xml_decl
            prolog_started = true
          elsif @scanner.match?("<!DOCTYPE")
            parse_doctype
            prolog_started = true
          elsif @scanner.match?("<!--")
            misc = parse_comment_rest
            misc.parent_node = @doc
            @doc.misc_before << misc
            prolog_started = true
          elsif @scanner.match?("<?")
            misc = parse_pi_rest
            misc.parent_node = @doc
            @doc.misc_before << misc
            prolog_started = true
          else
            break
          end
        else
          error("unexpected character before the root element")
        end
      end
    end

    private def parse_epilog : Nil
      loop do
        skip_s
        c = @scanner.peek
        return if c.nil?
        if c == '<'
          if @scanner.match?("<!--")
            misc = parse_comment_rest
            misc.parent_node = @doc
            @doc.misc_after << misc
          elsif @scanner.match?("<?")
            misc = parse_pi_rest
            misc.parent_node = @doc
            @doc.misc_after << misc
          else
            error("unexpected markup after the root element")
          end
        else
          error("unexpected character after the root element")
        end
      end
    end

    private def parse_xml_decl : Nil
      require_s("after '<?xml'")
      error("expected 'version' in the XML declaration") unless @scanner.match?("version")
      skip_s
      expect('=', "'=' in the XML declaration")
      skip_s
      version = parse_quoted_literal
      # VersionInfo ::= '1.' [0-9]+ - accept any 1.x and apply 1.0 rules.
      error("unsupported XML version '#{version}'") unless version =~ /^1\.\d+$/
      had_space = skip_s
      if @scanner.match?("encoding")
        error("expected whitespace before 'encoding'") unless had_space
        skip_s
        expect('=', "'=' in the XML declaration")
        skip_s
        enc = parse_quoted_literal
        error("invalid encoding name '#{enc}'") unless valid_enc_name?(enc)
        validate_encoding_declaration(enc)
        had_space = skip_s
      end
      if @scanner.match?("standalone")
        error("expected whitespace before 'standalone'") unless had_space
        skip_s
        expect('=', "'=' in the XML declaration")
        skip_s
        sa = parse_quoted_literal
        error("standalone must be 'yes' or 'no'") unless sa == "yes" || sa == "no"
      end
      skip_s
      expect('?', "'?>' terminating the XML declaration")
      expect('>', "'?>' terminating the XML declaration")
    end

    private def validate_encoding_declaration(enc : String) : Nil
      normalized = enc.downcase
      if bom = @bom_encoding
        error("encoding declaration '#{enc}' conflicts with the UTF-8 byte order mark") unless normalized == bom
      elsif normalized == "utf-16" || normalized == "utf-32"
        error("encoding '#{enc}' is incompatible with the document input")
      end
    end

    private def valid_enc_name?(enc : String) : Bool
      first = enc.char_at(0)
      return false unless 'A' <= first <= 'Z' || 'a' <= first <= 'z'
      enc.each_char.all? do |char|
        ('A' <= char <= 'Z') || ('a' <= char <= 'z') || ('0' <= char <= '9') ||
          char == '.' || char == '_' || char == '-'
      end
    end

    private def parse_quoted_literal : String
      q = @scanner.peek
      error("expected a quoted string") unless q == '"' || q == '\''
      @scanner.advance
      String.build do |b|
        loop do
          c = @scanner.peek
          error("unterminated quoted string") if c.nil?
          if c == q
            @scanner.advance
            break
          end
          b << @scanner.advance
        end
      end
    end

    # ------------------------------------------------------------------
    # comments and processing instructions

    private def parse_comment_rest : Comment
      b = String::Builder.new
      start_depth = @scanner.depth
      prev : Char? = nil
      prevprev : Char? = nil
      loop do
        error("comments must not span entity boundaries") if @scanner.depth < start_depth
        if prevprev == '-' && prev == '-'
          nxt = @scanner.peek
          if nxt == '>'
            @scanner.advance
            content = b.to_s
            content = content[0...content.size - 2]
            error("'--' is not allowed inside a comment") if content.includes?("--")
            error("comment content must not end with '-'") if content.ends_with?('-')
            c = Comment.new(content)
            c.doc_order = next_order
            return c
          elsif nxt.nil?
            error("unterminated comment")
          elsif nxt != '-'
            error("'--' is not allowed inside a comment")
          end
        end
        c = @scanner.peek
        error("unterminated comment") if c.nil?
        b << @scanner.advance
        prevprev = prev
        prev = c
      end
    end

    private def parse_pi_rest : ProcessingInstruction
      start_depth = @scanner.depth
      target = parse_name_raw
      error("processing instruction target '#{target}' is reserved") if target.downcase == "xml"
      error("processing instruction targets must not contain colons") if target.includes?(':')
      content = String::Builder.new
      c = @scanner.peek
      error("unterminated processing instruction") if c.nil?
      if whitespace?(c)
        while d = @scanner.peek
          break unless whitespace?(d)
          @scanner.advance
        end
      elsif c == '?'
        # fall through: expect immediate "?>"
      else
        error("expected whitespace or '?>' after the processing instruction target")
      end
      last_question = false
      loop do
        error("processing instructions must not span entity boundaries") if @scanner.depth < start_depth
        d = @scanner.peek
        error("unterminated processing instruction") if d.nil?
        ch = @scanner.advance
        if last_question && ch == '>'
          text = content.to_s
          text = text[0...text.size - 1]
          pi = ProcessingInstruction.new(target, text)
          pi.doc_order = next_order
          return pi
        end
        content << ch
        last_question = ch == '?'
      end
    end

    # ------------------------------------------------------------------
    # doctype and the internal subset

    private def parse_doctype : Nil
      require_s("after '<!DOCTYPE'")
      name = parse_name_raw
      pub : String? = nil
      sys : String? = nil
      skip_s
      if (c = @scanner.peek) && (c == 'S' || c == 'P')
        if @scanner.match?("SYSTEM")
          require_s("after 'SYSTEM'")
          sys = parse_quoted_literal
        elsif @scanner.match?("PUBLIC")
          require_s("after 'PUBLIC'")
          pub = parse_quoted_literal
          validate_pubid(pub)
          require_s("after the public identifier")
          sys = parse_quoted_literal
        else
          error("expected 'SYSTEM' or 'PUBLIC'")
        end
      end
      doctype = DocumentType.new(name, pub, sys)
      doctype.doc_order = next_order
      @doc.doctype = doctype
      skip_s
      if (c = @scanner.peek) && c == '['
        @scanner.advance
        parse_internal_subset
        skip_s
      end
      expect('>', "'>' terminating the DOCTYPE declaration")
    end

    private def validate_pubid(pub : String) : Nil
      pub.each_char do |char|
        ok = char == ' ' || char == '\r' || char == '\n' ||
             ('A' <= char <= 'Z') || ('a' <= char <= 'z') || ('0' <= char <= '9') ||
             "-'()+,./:=?;!*#@$_%".includes?(char)
        error("invalid character in public identifier") unless ok
      end
    end

    private def parse_internal_subset : Nil
      loop do
        skip_s
        c = @scanner.peek
        error("unterminated internal DTD subset") if c.nil?
        if c == ']'
          @scanner.advance
          return
        elsif c == '%'
          @scanner.advance
          @has_parameter_entity = true
          ref_depth = @scanner.depth
          name = parse_entity_ref_name(ref_depth)
          pe = @pes[name]?
          error("parameter entity '#{name}' is not declared") if pe.nil?
          error("external parameter entities are not supported") if pe.external?
          # 4.4.8 Included as PE: pad with one leading and trailing space.
          push_replacement(" #{pe.replacement} ", "parameter entity '#{name}'")
        elsif @scanner.match?("<!ENTITY")
          parse_entity_decl
        elsif @scanner.match?("<!ATTLIST")
          parse_attlist_decl
        elsif @scanner.match?("<!ELEMENT")
          parse_element_decl
        elsif @scanner.match?("<!NOTATION")
          parse_notation_decl
        elsif @scanner.match?("<!--")
          parse_comment_rest
        elsif @scanner.match?("<?")
          parse_pi_rest
        else
          error("expected a declaration in the internal DTD subset")
        end
      end
    end

    # [82] NotationDecl. Validated for well-formedness (name, external or
    # public identifier, PubidChar set).
    # [45] elementdecl with full content-model validation ([46]-[51],
    # [53 cp], [84]-[89] in IBM numbering) so malformed content models are
    # rejected as not well-formed.
    private def parse_element_decl : Nil
      require_s("after '<!ELEMENT'")
      parse_name_raw
      require_s("after the element name")
      parse_contentspec
      skip_s
      expect('>', "'>' terminating the ELEMENT declaration")
    end

    private def check_keyword_end : Nil
      c = @scanner.peek
      error("invalid keyword") if c && name_char?(c)
    end

    private def parse_contentspec : Nil
      if @scanner.match?("EMPTY") || @scanner.match?("ANY")
        check_keyword_end
        return
      end
      if (c = @scanner.peek) && c == '('
        @scanner.advance
        skip_s
        if @scanner.match?("#PCDATA")
          parse_mixed_tail
          return
        end
        parse_children_tail
        return
      end
      error("expected a content specification")
    end

    private def parse_occurrence_marker : Nil
      if (m = @scanner.peek) && (m == '?' || m == '*' || m == '+')
        @scanner.advance
      end
    end

    private def parse_cp : Nil
      c = @scanner.peek
      if c == '('
        @scanner.advance
        skip_s
        parse_children_tail
      else
        parse_name_raw
      end
      parse_occurrence_marker
    end

    private def parse_children_tail : Nil
      parse_cp
      skip_s
      c = @scanner.peek
      if c == ')'
        @scanner.advance
      elsif c == '|' || c == ','
        sep = c.as(Char)
        @scanner.advance
        loop do
          skip_s
          parse_cp
          skip_s
          c2 = @scanner.peek
          if c2 == sep
            @scanner.advance
          elsif c2 == ')'
            @scanner.advance
            break
          else
            error("expected '#{sep}' or ')' in the content model")
          end
        end
      else
        error("expected '|', ',' or ')' in the content model")
      end
      parse_occurrence_marker
    end

    private def parse_mixed_tail : Nil
      has_names = false
      loop do
        skip_s
        c = @scanner.peek
        error("unterminated mixed content model") if c.nil?
        if c == ')'
          @scanner.advance
          break
        elsif c == '|'
          @scanner.advance
          skip_s
          parse_name_raw
          has_names = true
        else
          error("expected '|' or ')' in the mixed content model")
        end
      end
      skip_s
      if has_names
        error("expected '*' after a mixed content model with names") unless @scanner.peek == '*'
        @scanner.advance
      elsif (m = @scanner.peek) && (m == '?' || m == '+' || m == '*')
        error("the PCDATA-only mixed content form allows no occurrence marker") unless m == '*'
        @scanner.advance
      end
    end

    private def parse_notation_decl : Nil
      require_s("after '<!NOTATION'")
      nname = parse_name_raw
      error("notation names must not contain colons") if nname.includes?(':')
      require_s("after the notation name")
      if @scanner.match?("SYSTEM")
        require_s("after 'SYSTEM'")
        parse_quoted_literal
      elsif @scanner.match?("PUBLIC")
        require_s("after 'PUBLIC'")
        pub = parse_quoted_literal
        validate_pubid(pub)
        had_space = skip_s
        if (c = @scanner.peek) && (c == '"' || c == '\'')
          error("expected whitespace before the system identifier") unless had_space
          parse_quoted_literal
        end
      else
        error("expected 'SYSTEM' or 'PUBLIC' in the notation declaration")
      end
      skip_s
      expect('>', "'>' terminating the NOTATION declaration")
    end

    private def skip_markup_decl : Nil
      quote : Char? = nil
      loop do
        c = @scanner.peek
        error("unterminated declaration") if c.nil?
        if q = quote
          quote = nil if c == q
        elsif c == '\'' || c == '"'
          quote = c
        elsif c == '&'
          error("references are not allowed in the DTD outside entity values")
        elsif c == '>'
          @scanner.advance
          return
        end
        @scanner.advance
      end
    end

    # Dependency graph for entity recursion detection (WFC: No Recursion,
    # checked at declaration time per the conformance suite's expectation).
    private def record_entity_deps(name : String, replacement : String) : Nil
      deps = @dep_graph[name] ||= Set(String).new
      i = 0
      size = replacement.bytesize
      while i < size
        ch, len = KXML.decode_char_at(replacement, i)
        if ch == '&'
          j = i + 1
          if j < size && replacement.byte_at(j) == 0x23
            # character reference - no dependency
            _, ni = char_ref_in_string(replacement, j)
            i = ni
          else
            name_end = replacement.byte_index(';', j)
            raise Error.new("bug: malformed bypassed reference", 0, 0) if name_end.nil?
            ref = replacement.byte_slice(j, name_end - j)
            deps << ref unless PREDEFINED_ENTITIES.has_key?(ref)
            i = name_end + 1
          end
        else
          i += len
        end
      end
      path = Set(String).new([name])
      check_entity_cycles(name, path, 0)
    end

    private def check_entity_cycles(node : String, path : Set(String), depth : Int32) : Nil
      error("recursive entity reference involving '#{node}'") if depth > MAX_ENTITY_DEPTH
      deps = @dep_graph[node]? || return
      deps.each do |dep|
        next if PREDEFINED_ENTITIES.has_key?(dep)
        error("recursive entity reference involving '#{dep}'") if path.includes?(dep)
        path << dep
        check_entity_cycles(dep, path, depth + 1)
        path.delete(dep)
      end
    end

    private def parse_entity_decl : Nil
      require_s("after '<!ENTITY'")
      is_pe = false
      if (c = @scanner.peek) && c == '%'
        @scanner.advance
        require_s("after '%'")
        is_pe = true
      end
      name = parse_name_raw
      error("entity names must not contain colons") if name.includes?(':')
      require_s("after the entity name")
      table = is_pe ? @pes : @entities
      c = @scanner.peek
      if c == '"' || c == '\''
        replacement = parse_entity_value(0)
        unless table.has_key?(name)
          table[name] = Entity.new(replacement)
          record_entity_deps(name, replacement)
        end
      else
        parse_external_id
        unparsed = false
        had_space = skip_s
        if @scanner.match?("NDATA")
          error("expected whitespace before 'NDATA'") unless had_space
          error("parameter entities cannot be unparsed") if is_pe
          require_s("after 'NDATA'")
          parse_name_raw
          unparsed = true
        end
        # External entities are recorded but never fetched; references to
        # them are rejected at use sites.
        table[name] = Entity.new("", true, unparsed) unless table.has_key?(name)
      end
      skip_s
      expect('>', "'>' terminating the ENTITY declaration")
    end

    private def parse_external_id : Nil
      if @scanner.match?("SYSTEM")
        require_s("after 'SYSTEM'")
        parse_quoted_literal
      elsif @scanner.match?("PUBLIC")
        require_s("after 'PUBLIC'")
        pub = parse_quoted_literal
        validate_pubid(pub)
        require_s("after the public identifier")
        parse_quoted_literal
      else
        error("expected 'SYSTEM' or 'PUBLIC'")
      end
    end

    # [9] EntityValue. Char references are expanded now (4.5), PE
    # references are included in literal, general entity references are
    # bypassed (left as-is).
    private def parse_entity_value(pe_depth : Int32) : String
      q = @scanner.peek
      error("expected an entity value") unless q == '"' || q == '\''
      @scanner.advance
      b = String::Builder.new
      loop do
        c = @scanner.peek
        error("unterminated entity value") if c.nil?
        if c == q
          @scanner.advance
          return b.to_s
        elsif c == '&'
          @scanner.advance
          nxt = @scanner.peek
          error("invalid reference in entity value") if nxt.nil?
          if nxt == '#'
            @scanner.advance
            cp = parse_char_ref_after_hash(@scanner.depth)
            b << cp.chr
          else
            name = parse_entity_ref_name(@scanner.depth)
            b << '&' << name << ';'
          end
        elsif c == '%'
          # WFC: PEs in Internal Subset - a PE reference must not occur
          # within a markup declaration, including inside an EntityValue.
          # (External subsets, where PEs in values are allowed, are not
          # fetched by this parser.)
          error("parameter entity references cannot occur within markup declarations in the internal DTD subset")
        else
          b << @scanner.advance
        end
      end
    end

    # ------------------------------------------------------------------
    # ATTLIST

    private def parse_attlist_decl : Nil
      require_s("after '<!ATTLIST'")
      elem_name = parse_name_raw
      table = @attlists[elem_name] ||= Hash(String, AttDef).new
      loop do
        skip_s
        c = @scanner.peek
        error("unterminated ATTLIST declaration") if c.nil?
        break if c == '>'
        error("expected an attribute definition") unless name_start_char?(c)
        attr_name = parse_name_raw
        require_s("after the attribute name")
        type = parse_att_type
        require_s("before the attribute default")
        default_raw, _fixed = parse_default_decl
        validate_default_refs(default_raw) if default_raw
        unless table.has_key?(attr_name)
          table[attr_name] = AttDef.new(type, default_raw, _fixed)
        end
      end
      expect('>', "'>' terminating the ATTLIST declaration")
    end

    private def parse_att_type : String
      if (c = @scanner.peek) && c == '('
        @scanner.advance
        skip_s
        parse_nmtoken
        loop do
          skip_s
          break if @scanner.peek == ')'
          expect('|', "'|' in an enumerated attribute type")
          skip_s
          parse_nmtoken
        end
        expect(')', "')' closing an enumerated attribute type")
        return "(enumeration)"
      end
      word = parse_name_raw
      case word
      when "CDATA", "ID", "IDREF", "IDREFS", "ENTITY", "ENTITIES", "NMTOKEN", "NMTOKENS"
        word
      when "NOTATION"
        require_s("after 'NOTATION'")
        expect('(', "'(' starting a notation type")
        skip_s
        parse_name_raw
        loop do
          skip_s
          break if @scanner.peek == ')'
          expect('|', "'|' in a notation type")
          skip_s
          parse_name_raw
        end
        expect(')', "')' closing a notation type")
        "NOTATION"
      else
        error("invalid attribute type '#{word}'")
      end
    end

    private def parse_nmtoken : String
      b = String::Builder.new
      while c = @scanner.peek
        break unless name_char?(c)
        b << @scanner.advance
      end
      tok = b.to_s
      error("expected a name token") if tok.empty?
      tok
    end

    private def parse_default_decl : {String?, Bool}
      if @scanner.match?("#REQUIRED")
        check_default_keyword_end
        {nil, false}
      elsif @scanner.match?("#IMPLIED")
        check_default_keyword_end
        {nil, false}
      elsif @scanner.match?("#FIXED")
        require_s("after '#FIXED'")
        q = @scanner.peek
        error("expected a quoted default value") unless q == '"' || q == '\''
        @scanner.advance
        {parse_att_literal(q.as(Char)), true}
      elsif (q = @scanner.peek) && (q == '"' || q == '\'')
        @scanner.advance
        {parse_att_literal(q), false}
      else
        error("expected an attribute default declaration")
      end
    end

    private def check_default_keyword_end : Nil
      c = @scanner.peek
      error("invalid attribute default keyword") if c && name_char?(c)
    end

    # Reads an AttValue literal keeping references in source form.
    private def parse_att_literal(quote : Char) : String
      b = String::Builder.new
      loop do
        # Fast path: batch plain bytes between references.
        if chunk = @scanner.read_attr_chunk(quote)
          b << chunk unless chunk.empty?
        else
          # The batch path bailed on a byte it cannot validate (or entity
          # sources are active). Consume one character through the checked
          # per-char path so the loop always makes progress; invalid
          # characters raise here.
          first = @scanner.peek
          error("unterminated attribute value") if first.nil?
          unless first == quote || first == '<' || first == '&'
            @scanner.advance
            b << first
          end
        end
        c = @scanner.peek
        error("unterminated attribute value") if c.nil?
        if c == quote
          @scanner.advance
          return b.to_s
        elsif c == '<'
          error("'<' is not allowed in attribute values")
        elsif c == '&'
          @scanner.advance
          nxt = @scanner.peek
          error("invalid reference in attribute value") if nxt.nil?
          if nxt == '#'
            @scanner.advance
            cp = parse_char_ref_after_hash(@scanner.depth)
            b << "&#" << cp.to_s << ';'
          else
            name = parse_entity_ref_name(@scanner.depth)
            validate_entity_ref_for_attribute(name)
            b << '&' << name << ';'
          end
        end
      end
    end

    private def validate_entity_ref_for_attribute(name : String) : Nil
      return if PREDEFINED_ENTITIES.has_key?(name)
      e = @entities[name]?
      error("entity '#{name}' is not declared") if e.nil?
      error("references to external entities are not allowed in attribute values") if e.external?
    end

    private def validate_default_refs(raw : String) : Nil
      i = 0
      while i < raw.bytesize
        ch, len = KXML.decode_char_at(raw, i)
        if ch == '&'
          j = i + 1
          if j < raw.bytesize && raw.byte_at(j) == 0x23
            _, ni = char_ref_in_string(raw, j)
            i = ni
          else
            name_end = raw.byte_index(';', j)
            error("unterminated entity reference in an attribute default") if name_end.nil?
            name = raw.byte_slice(j, name_end - j)
            unless PREDEFINED_ENTITIES.has_key?(name) || @entities.has_key?(name)
              error("entity '#{name}' must be declared before it is referenced in an attribute default")
            end
            i = name_end + 1
          end
        else
          i += len
        end
      end
    end

    # ------------------------------------------------------------------
    # attribute-value normalization (3.3.3)

    def normalize_att_value(raw : String, type : String) : String
      # Fast path: no references and no whitespace normalization needed.
      unless raw.includes?('&') || raw.includes?('\t') ||
             raw.includes?('\n') || raw.includes?('\r')
        return type == "CDATA" ? raw : collapse_spaces(raw)
      end
      b = String::Builder.new
      i = 0
      size = raw.bytesize
      while i < size
        ch, len = KXML.decode_char_at(raw, i)
        if ch == '&'
          j = i + 1
          if j < size && raw.byte_at(j) == 0x23
            cp, ni = char_ref_in_string(raw, j)
            b << cp.chr
            i = ni
          else
            name_end = raw.byte_index(';', j)
            raise Error.new("bug: malformed reference in normalized literal", 0, 0) if name_end.nil?
            append_entity_in_attribute(raw.byte_slice(j, name_end - j), b, 0)
            i = name_end + 1
          end
        elsif whitespace?(ch)
          b << ' '
          i += len
        else
          b << ch
          i += len
        end
      end
      value = b.to_s
      value = collapse_spaces(value) unless type == "CDATA"
      value
    end

    private def append_entity_in_attribute(name : String, b : String::Builder, depth : Int32) : Nil
      case name
      when "lt"   then b << '<'
      when "gt"   then b << '>'
      when "amp"  then b << '&'
      when "apos" then b << '\''
      when "quot" then b << '"'
      else
        e = @entities[name]?
        raise Error.new("bug: entity '#{name}' missing during normalization", 0, 0) if e.nil?
        error("references to external entities are not allowed in attribute values") if e.external?
        walk_entity_replacement(e.replacement, b, depth + 1)
      end
    end

    # Recursively process an entity replacement text per 3.3.3 step 3:
    # char references append the referenced character, general entity
    # references recurse, literal whitespace becomes a space, and a
    # literal '<' in the replacement text is a fatal error (WFC:
    # No < in Attribute Values).
    private def walk_entity_replacement(text : String, b : String::Builder, depth : Int32) : Nil
      error("entity references nested too deeply in an attribute value") if depth > MAX_ENTITY_DEPTH
      i = 0
      size = text.bytesize
      while i < size
        ch, len = KXML.decode_char_at(text, i)
        if ch == '&'
          j = i + 1
          if j < size && text.byte_at(j) == 0x23
            cp, ni = char_ref_in_string(text, j)
            b << cp.chr
            i = ni
          else
            name_end = text.index(';', j)
            raise Error.new("bug: malformed bypassed reference", 0, 0) if name_end.nil?
            append_entity_in_attribute(text[j...name_end], b, depth)
            i = name_end + 1
          end
        elsif ch == '<'
          error("'<' in an entity replacement text is not allowed in attribute values")
        elsif whitespace?(ch)
          b << ' '
          i += len
        else
          b << ch
          i += len
        end
      end
    end

    private def char_ref_in_string(s : String, hash_index : Int32) : {Int32, Int32}
      i = hash_index + 1
      hex = false
      if i < s.size
        c = KXML.decode_char_at(s, i)[0]
        if c == 'x' || c == 'X'
          hex = true
          i += 1
        end
      end
      start = i
      while i < s.bytesize
        c = KXML.decode_char_at(s, i)[0]
        ok = hex ? ascii_hex_digit?(c) : c.ascii_number?
        break unless ok
        i += 1
      end
      error("character reference contains no digits") if i == start
      error("unterminated character reference") if i >= s.bytesize || KXML.decode_char_at(s, i)[0] != ';'
      cp = s.byte_slice(start, i - start).to_i(hex ? 16 : 10)
      error("character reference out of range") if cp > 0x10FFFF
      error("character reference to an invalid XML character") unless Parser.valid_codepoint?(cp)
      {cp, i + 1}
    end

    private def collapse_spaces(v : String) : String
      return "" if v.empty?

      String.build do |builder|
        pending_space = false
        has_output = false
        v.each_char do |char|
          if char == ' '
            pending_space = true
          else
            builder << ' ' if pending_space && has_output
            builder << char
            pending_space = false
            has_output = true
          end
        end
      end
    end

    # ------------------------------------------------------------------
    # elements

    private def parse_element : Element
      @element_depth += 1
      error("element nesting exceeds the maximum depth") if @element_depth > MAX_ELEMENT_DEPTH
      error("expected '<'") unless @scanner.peek == '<'
      @scanner.advance
      raw_name = parse_name_raw
      eprefix, elocal = split_qname(raw_name)
      elocal = raw_name unless eprefix
      elem_order = next_order

      raw_attrs = [] of {String, String?, String, String, Bool, Int32}
      seen_attr_names = Set(String).new
      self_closing = false
      loop do
        had_space = skip_s
        c = @scanner.peek
        error("unexpected end of file in the start tag of '#{raw_name}'") if c.nil?
        if c == '>'
          @scanner.advance
          break
        elsif c == '/'
          @scanner.advance
          expect('>', "'>' closing the empty-element tag")
          self_closing = true
          break
        else
          error("whitespace is required before attribute '#{c}'") unless had_space
          ap_raw = parse_name_raw
          a_pfx, a_local = split_qname(ap_raw)
          a_local = ap_raw unless a_pfx
          skip_s
          error("expected '=' after attribute name '#{ap_raw}'") unless @scanner.peek == '='
          @scanner.advance
          skip_s
          q = @scanner.peek
          error("expected a quoted attribute value") unless q == '"' || q == '\''
          @scanner.advance
          raw_value = parse_att_literal(q.as(Char))
          value = normalize_att_value(raw_value, attribute_type(raw_name, ap_raw))
          error("duplicate attribute '#{ap_raw}'") unless seen_attr_names.add?(ap_raw)
          raw_attrs << {ap_raw, a_pfx, a_local, value, true, next_order}
        end
      end

      apply_attribute_defaults(raw_name, raw_attrs)
      scope = build_scope(raw_attrs)
      elem_uri = resolve_element_namespace(scope, eprefix, raw_name)
      attributes = resolve_attribute_namespaces(scope, raw_attrs)
      elem = Element.new(raw_name, eprefix, elocal, elem_uri, attributes)
      elem.doc_order = elem_order

      @ns_stack.push(scope)
      if self_closing
        @ns_stack.pop
        @element_depth -= 1
        return elem
      end
      parse_content(elem)
      @ns_stack.pop
      @element_depth -= 1
      elem
    end

    private def attribute_type(elem_name : String, attr_name : String) : String
      if table = @attlists[elem_name]?
        if defn = table[attr_name]?
          if defn.type == "ID"
            @doc.id_attribute_names << attr_name
          end
          return defn.type
        end
      end
      "CDATA"
    end

    private def apply_attribute_defaults(elem_name : String, raw_attrs : Array({String, String?, String, String, Bool, Int32})) : Nil
      return unless table = @attlists[elem_name]?
      table.each do |attr_name, defn|
        next if raw_attrs.any? { |raw| raw[0] == attr_name }
        if dv = defn.default_raw
          a_pfx, a_local = split_qname(attr_name)
          raw_attrs << {attr_name, a_pfx, a_local, normalize_att_value(dv, defn.type), false, next_order}
        end
      end
    end

    private def drain_popped_depths : Nil
      while pair = @scanner.popped_depths.shift?
        recorded, at_pop = pair
        error("entity replacement text has unbalanced markup") if at_pop != recorded
      end
    end

    private def parse_content(elem : Element) : Nil
      loop do
        drain_popped_depths
        c = @scanner.peek
        if c.nil?
          flush_text(elem)
          error("unexpected end of file: element '#{elem.name}' is not closed")
        end
        if c == '<'
          if @scanner.match?("</")
            flush_text(elem)
            parse_end_tag(elem)
            return
          elsif @scanner.match?("<!--")
            flush_text(elem)
            child = parse_comment_rest
            child.parent_node = elem
            elem.children << child
          elsif @scanner.match?("<![CDATA[")
            flush_text(elem)
            child = parse_cdata_rest
            child.parent_node = elem
            elem.children << child
          elsif @scanner.match?("<?")
            flush_text(elem)
            child = parse_pi_rest
            child.parent_node = elem
            elem.children << child
          elsif @scanner.match?("<!")
            error("unexpected '<!' in element content")
          else
            flush_text(elem)
            child = parse_element
            child.parent_node = elem
            elem.children << child
          end
        elsif c == '&'
          @scanner.advance
          nxt = @scanner.peek
          error("invalid reference in content") if nxt.nil?
          if nxt == '#'
            @scanner.advance
            cp = parse_char_ref_after_hash(@scanner.depth)
            append_text_char(cp.chr)
            @raw_pp = nil
            @raw_prev = nil
          else
            name = parse_entity_ref_name(@scanner.depth)
            expand_entity_in_content(name)
          end
        else
          label = @scanner.label
          if label != @raw_label
            @raw_pp = nil
            @raw_prev = nil
            @raw_label = label
          end
          if (pp = @raw_pp) && (pv = @raw_prev) && pp == ']' && pv == ']' && @scanner.peek == '>'
            error("']]>' is not allowed in character data")
          end
          pending = 0
          pending += 1 if (pv = @raw_prev) && pv == ']'
          pending += 1 if (pp = @raw_pp) && pp == ']'
          chunk = @scanner.read_plain_text(pending)
          if chunk && !chunk.empty?
            append_text_chunk(chunk)
            # Track the trailing ']' run across chunks (only ']]>' matters).
            run = pending
            i = chunk.bytesize - 1
            while i >= 0 && chunk.byte_at(i) == 0x5D && run < 2
              run += 1
              i -= 1
            end
            @raw_pp = run >= 2 ? ']' : nil
            @raw_prev = run >= 1 ? ']' : nil
            next
          end
          ch = @scanner.advance
          append_text_char(ch)
          @raw_pp = @raw_prev
          @raw_prev = ch
        end
      end
    end

    private def text_buf : String::Builder
      unless buf = @text_buf
        buf = String::Builder.new
        @text_buf = buf
        @text_buf_order = next_order
      end
      buf
    end

    # Appends plain text, avoiding the String::Builder when possible.
    private def append_text_chunk(s : String) : Nil
      if buf = @text_buf
        buf << s
      elsif pt = @pending_text
        buf = text_buf
        buf << pt << s
        @text_buf = buf
        @pending_text = nil
      else
        @pending_text = s
        @text_buf_order = next_order unless @text_buf_order
      end
    end

    # Appends a single char (from a character reference), promoting any
    # pending string into the builder.
    private def append_text_char(ch : Char) : Nil
      if pt = @pending_text
        buf = text_buf
        buf << pt << ch
        @text_buf = buf
        @pending_text = nil
      else
        text_buf << ch
      end
    end

    private def reset_raw_tracking : Nil
      @raw_pp = nil
      @raw_prev = nil
      @raw_label = nil
    end

    private def flush_text(elem : Element) : Nil
      reset_raw_tracking
      s = nil
      order = nil
      if buf = @text_buf
        @text_buf = nil
        order = @text_buf_order.as(Int32)
        @text_buf_order = nil
        s = buf.to_s
      elsif pt = @pending_text
        @pending_text = nil
        order = @text_buf_order.as(Int32)
        @text_buf_order = nil
        s = pt
      end
      return if s.nil? || s.as(String).empty?
      text = s.as(String)
      ord = order.as(Int32)
      last = elem.children.last?
      if last.is_a?(Text)
        last.content += text
      else
        t = Text.new(text)
        t.doc_order = ord
        t.parent_node = elem
        elem.children << t
      end
    end

    private def parse_end_tag(elem : Element) : Nil
      error("entity replacement text cannot close an element opened outside it") if @element_depth <= @scanner.top_push_elem_depth
      name = parse_name_raw
      skip_s
      expect('>', "'>' terminating the end tag")
      error("mismatched end tag: expected '#{elem.name}' but found '#{name}'") unless name == elem.name
    end

    private def parse_cdata_rest : CData
      b = String::Builder.new
      start_depth = @scanner.depth
      prev : Char? = nil
      prevprev : Char? = nil
      loop do
        error("CDATA sections must not span entity boundaries") if @scanner.depth < start_depth
        if prevprev == ']' && prev == ']' && @scanner.peek == '>'
          @scanner.advance
          content = b.to_s
          content = content[0...content.size - 2]
          cdata = CData.new(content)
          cdata.doc_order = next_order
          return cdata
        end
        c = @scanner.peek
        error("unterminated CDATA section") if c.nil?
        b << @scanner.advance
        prevprev = prev
        prev = c
      end
    end

    private def expand_entity_in_content(name : String) : Nil
      if rep = PREDEFINED_ENTITIES[name]?
        push_replacement(rep, "predefined entity '#{name}'", @element_depth)
        return
      end
      e = @entities[name]?
      return if e.nil? && @has_parameter_entity
      error("entity '#{name}' is not declared") if e.nil?
      error("external entity '#{name}' cannot be included (external entities are not supported)") if e.external?
      push_replacement(e.replacement, "entity '#{name}'", @element_depth)
    end

    private def push_replacement(replacement : String, label : String, elem_depth : Int32 = -1) : Nil
      @raw_pp = nil
      @raw_prev = nil
      @raw_label = nil
      return if replacement.empty?
      @expanded_bytes += replacement.bytesize
      error("entity expansion exceeds the maximum total size") if @expanded_bytes > MAX_EXPANDED_BYTES
      error("entity references nested too deeply") if @scanner.depth + 1 > MAX_ENTITY_DEPTH
      @scanner.push(replacement, label, elem_depth)
    end

    # ------------------------------------------------------------------
    # namespaces (XML Namespaces 1.0)

    private def build_scope(raw_attrs : Array({String, String?, String, String, Bool, Int32})) : Hash(String, String?)
      # Fast path: no xmlns declarations - share the parent scope (it is
      # never mutated by callers, only read).
      has_ns_decl = raw_attrs.any? do |_, pfx, local, _, _|
        pfx == "xmlns" || (pfx.nil? && local == "xmlns")
      end
      return @ns_stack.last unless has_ns_decl
      scope = @ns_stack.last.dup
      raw_attrs.each do |_, pfx, local, value, _|
        if pfx == "xmlns"
          error("the xmlns prefix cannot be redeclared") if local == "xmlns"
          error("prefixed namespace declarations cannot use an empty URI") if value.empty?
          if local == "xml"
            error("the xml prefix may only be bound to #{XML_NAMESPACE_URI}") unless value == XML_NAMESPACE_URI
          elsif value == XML_NAMESPACE_URI
            error("only the xml prefix may be bound to the xml namespace")
          elsif value == XMLNS_NAMESPACE_URI
            error("no prefix may be bound to the xmlns namespace")
          end
          scope[local] = value
        elsif pfx.nil? && local == "xmlns"
          if value.empty?
            scope[""] = nil
          else
            error("the xmlns namespace cannot be the default namespace") if value == XMLNS_NAMESPACE_URI
            error("the xml namespace cannot be the default namespace") if value == XML_NAMESPACE_URI
            scope[""] = value
          end
        end
      end
      scope
    end

    private def resolve_element_namespace(scope : Hash(String, String?), prefix : String?, raw_name : String) : String?
      if pfx = prefix
        uri = scope[pfx]?
        error("namespace prefix '#{pfx}' on element '#{raw_name}' has not been declared") if uri.nil? || uri.empty?
        uri
      else
        scope[""]?
      end
    end

    private def resolve_attribute_namespaces(scope : Hash(String, String?), raw_attrs : Array({String, String?, String, String, Bool, Int32})) : Array(Attribute)
      # Fast path: no namespace-prefixed or xmlns attributes - all
      # attributes are no-namespace; the duplicate check is a linear scan
      # (attribute lists are small).
      ns_free = raw_attrs.all? do |_, pfx, local, _, _|
        pfx.nil? && local != "xmlns"
      end
      if ns_free
        attributes = raw_attrs.map do |raw, pfx, local, value, specified, order|
          a = Attribute.new(raw, pfx, local, nil, value, specified)
          a.doc_order = order
          a
        end
        seen = Set(String).new
        attributes.each do |a|
          error("duplicate attribute '#{a.name}'") unless seen.add?(a.name)
        end
        return attributes
      end
      attributes = raw_attrs.map do |raw, pfx, local, value, specified, order|
        uri =
          if pfx == "xmlns" || (pfx.nil? && local == "xmlns")
            XMLNS_NAMESPACE_URI
          elsif pfx
            u = scope[pfx]?
            error("namespace prefix '#{pfx}' on attribute '#{raw}' has not been declared") if u.nil? || u.empty?
            u
          end
        a = Attribute.new(raw, pfx, local, uri, value, specified)
        a.doc_order = order
        a
      end
      seen = Set({String?, String}).new
      attributes.each do |a|
        next if a.prefix == "xmlns" || (a.prefix.nil? && a.local_name == "xmlns")
        key = {a.namespace_uri, a.local_name}
        error("namespace conflict on attribute '#{a.local_name}'") unless seen.add?(key)
      end
      attributes
    end
  end

  # Parses *source* as an XML 1.0 document. Raises `KXML::Error` on any
  # well-formedness violation.
  def self.parse(source : String) : Document
    Parser.parse(source)
  end
end
