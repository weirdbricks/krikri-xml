require "./nodes"

module KXML
  # Decodes the UTF-8 character at byte position *pos* in *s* and returns
  # it with its byte length. String#char_at indexes by character, which is
  # wrong for a byte-driven scanner.
  def self.decode_char_at(s : String, pos : Int) : {Char, Int32}
    b0 = s.byte_at(pos).to_i
    if b0 < 0x80
      {b0.chr, 1}
    elsif b0 < 0xE0
      b1 = s.byte_at(pos + 1).to_i
      {(((b0 & 0x1F) << 6) | (b1 & 0x3F)).chr, 2}
    elsif b0 < 0xF0
      b1 = s.byte_at(pos + 1).to_i
      b2 = s.byte_at(pos + 2).to_i
      {(((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F)).chr, 3}
    else
      b1 = s.byte_at(pos + 1).to_i
      b2 = s.byte_at(pos + 2).to_i
      b3 = s.byte_at(pos + 3).to_i
      {(((b0 & 0x07) << 18) | ((b1 & 0x3F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F)).chr, 4}
    end
  end
  # Strict, pure-Crystal XML 1.0 (Fifth Edition) parser.
  #
  # Implemented directly from W3C REC-xml-20081126 (well-formedness only,
  # no DTD validation). Raises `KXML::Error` on any well-formedness
  # violation, mirroring lxml's non-recovering behavior.
  class Parser
    MAX_ELEMENT_DEPTH  = 10_000
    MAX_ENTITY_DEPTH   = 64
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
      getter external : Bool
      getter unparsed : Bool

      def initialize(@replacement : String, @external = false, @unparsed = false)
      end
    end

    private struct AttDef
      getter type : String
      getter default_raw : String?
      getter fixed : Bool

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
      @sources  = [] of String
      @labels   = [] of String
      @positions = [] of Int32
      @lines    = [] of Int32
      @cols     = [] of Int32

      def initialize(source : String, label : String)
        push(source, label)
      end

      def push(source : String, label : String) : Nil
        @sources << source
        @labels << label
        @positions << 0
        @lines << 1
        @cols << 0
      end

      # Number of pushed (entity) sources above the base document.
      def depth : Int32
        @sources.size - 1
      end

      def base_pos : Int32
        @positions.first
      end

      def label : String
        @labels.last
      end

      def line : Int32
        @lines.last
      end

      def column : Int32
        @cols.last
      end

      private def compact : Nil
        while @sources.size > 1 && @positions.last >= @sources.last.bytesize
          @sources.pop
          @labels.pop
          @positions.pop
          @lines.pop
          @cols.pop
        end
      end

      def eof? : Bool
        compact
        @sources.size == 1 && @positions.last >= @sources.last.bytesize
      end

      def peek : Char?
        return nil if eof?
        KXML.decode_char_at(@sources.last, @positions.last)[0]
      end

      def advance : Char
        compact
        raise "scanner bug: advance at EOF" if @positions.last >= @sources.last.bytesize
        ch, len = KXML.decode_char_at(@sources.last, @positions.last)
        @positions[@positions.size - 1] += len
        if ch == '\n'
          @lines[@lines.size - 1] += 1
          @cols[@cols.size - 1] = 0
        else
          @cols[@cols.size - 1] += 1
        end
        ch
      end

      # Consume *str* if the next characters match it (possibly across
      # entity-source boundaries); otherwise restore the exact state.
      def match?(str : String) : Bool
        saved_sources  = @sources.dup
        saved_labels   = @labels.dup
        saved_positions = @positions.dup
        saved_lines    = @lines.dup
        saved_cols     = @cols.dup
        ok = true
        str.each_char do |ch|
          p = peek
          if p.nil? || p != ch
            ok = false
            break
          end
          advance
        end
        unless ok
          @sources = saved_sources
          @labels = saved_labels
          @positions = saved_positions
          @lines = saved_lines
          @cols = saved_cols
        end
        ok
      end
    end

    @scanner : Scanner
    @doc = Document.new
    @entities = {} of String => Entity
    @pes = {} of String => Entity
    @attlists = {} of String => Hash(String, AttDef)
    @ns_stack = [] of Hash(String, String?)
    @element_depth = 0
    @expanded_bytes = 0
    @text_buf : String::Builder? = nil

    def initialize(source : String)
      @scanner = Scanner.new(source, "document")
      base = Hash(String, String?).new
      base["xml"] = XML_NAMESPACE_URI
      @ns_stack << base
    end

    def self.parse(source : String) : Document
      normalized = normalize_eol(source)
      validate_chars(normalized)
      new(normalized).parse
    end

    # 2.11: #xD#xA and any lone #xD become #xA on input, before parsing.
    def self.normalize_eol(source : String) : String
      return source unless source.includes?('\r')
      source.gsub("\r\n", "\n").gsub('\r', '\n')
    end

    private def self.validate_chars(source : String) : Nil
      byte_pos = 0
      source.each_char do |ch|
        unless valid_codepoint?(ch.ord)
          raise Error.new("invalid XML character U+#{ch.ord.to_s(16)}", 1, byte_pos, "document")
        end
        byte_pos += ch.bytesize
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
      String.build do |b|
        b << @scanner.advance
        while d = @scanner.peek
          break unless name_char?(d)
          b << @scanner.advance
        end
      end
    end

    private def split_qname(raw : String) : {String?, String}
      parts = raw.split(':')
      if parts.size > 2 || parts.any?(&.empty?)
        error("invalid name '#{raw}'")
      end
      parts.size == 2 ? {parts[0], parts[1]} : {nil, raw}
    end

    # Parses '#'... ';' (the '#' already consumed) and validates the
    # codepoint against production [2] Char.
    private def parse_char_ref_after_hash : Int32
      hex = false
      if x = @scanner.peek
        if x == 'x' || x == 'X'
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
      error("unterminated character reference (expected ';')") unless @scanner.peek == ';'
      @scanner.advance
      cp = digs.to_i(hex ? 16 : 10)
      error("character reference out of range") if cp > 0x10FFFF
      error("character reference to an invalid XML character") unless Parser.valid_codepoint?(cp)
      cp
    end

    # Parses Name ';' (the '&' already consumed).
    private def parse_entity_ref_name : String
      name = parse_name_raw
      error("unterminated entity reference (expected ';')") unless @scanner.peek == ';'
      @scanner.advance
      name
    end

    # ------------------------------------------------------------------
    # entry point

    def parse : Document
      skip_bom
      parse_prolog
      @doc.root = parse_element
      parse_epilog
      @doc
    end

    private def skip_bom : Nil
      if (c = @scanner.peek) && c.ord == 0xFEFF
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
            @doc.misc_before << parse_comment_rest
            prolog_started = true
          elsif @scanner.match?("<?")
            @doc.misc_before << parse_pi_rest
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
            @doc.misc_after << parse_comment_rest
          elsif @scanner.match?("<?")
            @doc.misc_after << parse_pi_rest
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
      error("unsupported XML version '#{version}' (only 1.0 is implemented)") unless version == "1.0"
      skip_s
      if @scanner.match?("encoding")
        skip_s
        expect('=', "'=' in the XML declaration")
        skip_s
        enc = parse_quoted_literal
        error("invalid encoding name '#{enc}'") unless valid_enc_name?(enc)
      end
      skip_s
      if @scanner.match?("standalone")
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

    private def valid_enc_name?(enc : String) : Bool
      first = enc.char_at(0)
      return false unless 'A' <= first <= 'Z' || 'a' <= first <= 'z'
      enc.each_char.all? do |ch|
        ('A' <= ch <= 'Z') || ('a' <= ch <= 'z') || ('0' <= ch <= '9') ||
          ch == '.' || ch == '_' || ch == '-'
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
      prev : Char? = nil
      prevprev : Char? = nil
      loop do
        if prevprev == '-' && prev == '-'
          nxt = @scanner.peek
          if nxt == '>'
            @scanner.advance
            content = b.to_s
            content = content[0...content.size - 2]
            error("'--' is not allowed inside a comment") if content.includes?("--")
            return Comment.new(content)
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
      target = parse_name_raw
      error("processing instruction target '#{target}' is reserved") if target.downcase == "xml"
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
        d = @scanner.peek
        error("unterminated processing instruction") if d.nil?
        ch = @scanner.advance
        if last_question && ch == '>'
          text = content.to_s
          text = text[0...text.size - 1]
          return ProcessingInstruction.new(target, text)
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
      @doc.doctype = DocumentType.new(name, pub, sys)
      skip_s
      if (c = @scanner.peek) && c == '['
        @scanner.advance
        parse_internal_subset
        skip_s
      end
      expect('>', "'>' terminating the DOCTYPE declaration")
    end

    private def validate_pubid(pub : String) : Nil
      pub.each_char do |ch|
        ok = whitespace?(ch) || ('A' <= ch <= 'Z') || ('a' <= ch <= 'z') ||
             ('0' <= ch <= '9') ||
             "-'()+,./:=?;!*#@$_%".includes?(ch)
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
          name = parse_entity_ref_name
          pe = @pes[name]?
          error("parameter entity '#{name}' is not declared") if pe.nil?
          error("external parameter entities are not supported") if pe.external
          # 4.4.8 Included as PE: pad with one leading and trailing space.
          push_replacement(" #{pe.replacement} ", "parameter entity '#{name}'")
        elsif @scanner.match?("<!ENTITY")
          parse_entity_decl
        elsif @scanner.match?("<!ATTLIST")
          parse_attlist_decl
        elsif @scanner.match?("<!ELEMENT") || @scanner.match?("<!NOTATION")
          skip_markup_decl
        elsif @scanner.match?("<!--")
          parse_comment_rest
        elsif @scanner.match?("<?")
          parse_pi_rest
        else
          error("expected a declaration in the internal DTD subset")
        end
      end
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

    private def parse_entity_decl : Nil
      require_s("after '<!ENTITY'")
      is_pe = false
      if (c = @scanner.peek) && c == '%'
        @scanner.advance
        require_s("after '%'")
        is_pe = true
      end
      name = parse_name_raw
      require_s("after the entity name")
      table = is_pe ? @pes : @entities
      c = @scanner.peek
      if c == '"' || c == '\''
        replacement = parse_entity_value(0)
        table[name] = Entity.new(replacement) unless table.has_key?(name)
      else
        parse_external_id
        unparsed = false
        skip_s
        if @scanner.match?("NDATA")
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
            cp = parse_char_ref_after_hash
            b << cp.chr
          else
            name = parse_entity_ref_name
            b << '&' << name << ';'
          end
        elsif c == '%'
          @scanner.advance
          name = parse_entity_ref_name
          pe = @pes[name]?
          error("parameter entity '#{name}' is not declared") if pe.nil?
          error("external parameter entities are not supported") if pe.external
          error("parameter entity references nested too deeply") if pe_depth >= MAX_ENTITY_DEPTH
          b << pe.replacement
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
        {parse_att_literal(q.not_nil!), true}
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
            cp = parse_char_ref_after_hash
            b << "&#" << cp.to_s << ';'
          else
            name = parse_entity_ref_name
            validate_entity_ref_for_attribute(name)
            b << '&' << name << ';'
          end
        else
          b << @scanner.advance
        end
      end
    end

    private def validate_entity_ref_for_attribute(name : String) : Nil
      return if PREDEFINED_ENTITIES.has_key?(name)
      e = @entities[name]?
      error("entity '#{name}' is not declared") if e.nil?
      error("references to external entities are not allowed in attribute values") if e.external
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
            name_end = raw.index(';', j)
            error("unterminated entity reference in an attribute default") if name_end.nil?
            name = raw[j...name_end]
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
            name_end = raw.index(';', j)
            raise Error.new("bug: malformed reference in normalized literal", 0, 0) if name_end.nil?
            append_entity_in_attribute(raw[j...name_end], b, 0)
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
      when "lt" then b << '<'
      when "gt" then b << '>'
      when "amp" then b << '&'
      when "apos" then b << '\''
      when "quot" then b << '"'
      else
        e = @entities[name]?
        raise Error.new("bug: entity '#{name}' missing during normalization", 0, 0) if e.nil?
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
        c = s.char_at(i)
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
      cp = s[start...i].to_i(hex ? 16 : 10)
      error("character reference out of range") if cp > 0x10FFFF
      error("character reference to an invalid XML character") unless Parser.valid_codepoint?(cp)
      {cp, i + 1}
    end

    private def collapse_spaces(v : String) : String
      v.split(' ').reject(&.empty?).join(' ')
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

      raw_attrs = [] of {String, String?, String, String, Bool}
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
          skip_s
          error("expected '=' after attribute name '#{ap_raw}'") unless @scanner.peek == '='
          @scanner.advance
          skip_s
          q = @scanner.peek
          error("expected a quoted attribute value") unless q == '"' || q == '\''
          @scanner.advance
          raw_value = parse_att_literal(q.not_nil!)
          value = normalize_att_value(raw_value, attribute_type(raw_name, ap_raw))
          error("duplicate attribute '#{ap_raw}'") if raw_attrs.any? { |r| r[0] == ap_raw }
          raw_attrs << {ap_raw, a_pfx, a_local, value, true}
        end
      end

      apply_attribute_defaults(raw_name, raw_attrs)
      scope = build_scope(raw_attrs)
      elem_uri = resolve_element_namespace(scope, eprefix, raw_name)
      attributes = resolve_attribute_namespaces(scope, raw_attrs)
      elem = Element.new(raw_name, eprefix, elocal, elem_uri, attributes)

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
          return defn.type
        end
      end
      "CDATA"
    end

    private def apply_attribute_defaults(elem_name : String, raw_attrs : Array({String, String?, String, String, Bool})) : Nil
      return unless table = @attlists[elem_name]?
      table.each do |attr_name, defn|
        next if raw_attrs.any? { |r| r[0] == attr_name }
        if dv = defn.default_raw
          a_pfx, a_local = split_qname(attr_name)
          raw_attrs << {attr_name, a_pfx, a_local, normalize_att_value(dv, defn.type), false}
        end
      end
    end

    private def parse_content(elem : Element) : Nil
      loop do
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
            cp = parse_char_ref_after_hash
            text_buf << cp.chr
          else
            name = parse_entity_ref_name
            expand_entity_in_content(name)
          end
        else
          ch = @scanner.advance
              text_buf << ch
        end
      end
    end

    private def text_buf : String::Builder
      @text_buf ||= String::Builder.new
    end

    private def flush_text(elem : Element) : Nil
      if buf = @text_buf
        @text_buf = nil
        s = buf.to_s
        return if s.empty?
        error("']]>' is not allowed in character data") if s.includes?("]]>")
        last = elem.children.last?
        if last.is_a?(Text)
          last.content += s
        else
          t = Text.new(s)
          t.parent_node = elem
          elem.children << t
        end
      end
    end

    private def parse_end_tag(elem : Element) : Nil
      name = parse_name_raw
      skip_s
      expect('>', "'>' terminating the end tag")
      error("mismatched end tag: expected '#{elem.name}' but found '#{name}'") unless name == elem.name
    end

    private def parse_cdata_rest : CData
      b = String::Builder.new
      prev : Char? = nil
      prevprev : Char? = nil
      loop do
        if prevprev == ']' && prev == ']' && @scanner.peek == '>'
          @scanner.advance
          content = b.to_s
          content = content[0...content.size - 2]
          return CData.new(content)
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
        push_replacement(rep, "predefined entity '#{name}'")
        return
      end
      e = @entities[name]?
      error("entity '#{name}' is not declared") if e.nil?
      error("external entity '#{name}' cannot be included (external entities are not supported)") if e.external
      push_replacement(e.replacement, "entity '#{name}'")
    end

    private def push_replacement(replacement : String, label : String) : Nil
      return if replacement.empty?
      @expanded_bytes += replacement.bytesize
      error("entity expansion exceeds the maximum total size") if @expanded_bytes > MAX_EXPANDED_BYTES
      error("entity references nested too deeply") if @scanner.depth + 1 > MAX_ENTITY_DEPTH
      @scanner.push(replacement, label)
    end

    # ------------------------------------------------------------------
    # namespaces (XML Namespaces 1.0)

    private def build_scope(raw_attrs : Array({String, String?, String, String, Bool})) : Hash(String, String?)
      scope = @ns_stack.last.dup
      raw_attrs.each do |_, pfx, local, value, _|
        if pfx == "xmlns"
          error("the xmlns prefix cannot be redeclared") if local == "xmlns"
          error("prefixed namespace declarations cannot use an empty URI") if value.empty?
          if local == "xml" && value != XML_NAMESPACE_URI
            error("the xml prefix may only be bound to #{XML_NAMESPACE_URI}")
          end
          scope[local] = value
        elsif pfx.nil? && local == "xmlns"
          scope[""] = value.empty? ? nil : value
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

    private def resolve_attribute_namespaces(scope : Hash(String, String?), raw_attrs : Array({String, String?, String, String, Bool})) : Array(Attribute)
      attributes = raw_attrs.map do |raw, pfx, local, value, specified|
        uri =
          if pfx == "xmlns" || (pfx.nil? && local == "xmlns")
            XMLNS_NAMESPACE_URI
          elsif pfx
            u = scope[pfx]?
            error("namespace prefix '#{pfx}' on attribute '#{raw}' has not been declared") if u.nil? || u.empty?
            u
          else
            nil
          end
        Attribute.new(raw, pfx, local, uri, value, specified)
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
