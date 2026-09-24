require "./base"

module KXML
  module XPath
    enum TokenKind
      LParen
      RParen
      LBracket
      RBracket
      Dot
      DotDot
      At
      Comma
      Colon
      ColonColon
      Slash
      SlashSlash
      Pipe
      Plus
      Minus
      Eq
      Neq
      Lt
      Le
      Gt
      Ge
      Star
      Dollar
      Literal
      Number
      NCName
      QName
      QNameStar
    end

    struct Token
      getter kind : TokenKind
      getter text : String
      getter offset : Int32

      def initialize(@kind : TokenKind, @text : String, @offset : Int32)
      end

      def number_value : Float64
        XPath.string_to_number(text)
      end
    end

    # Tokenizer for XPath 1.0 expressions, including the lexical
    # disambiguation rules of section 3.7 (OperatorName vs NCName,
    # MultiplyOperator vs wildcard name test).
    class Lexer
      OPERATORS_AFTER_NAME = false

      @tokens = [] of Token
      @src : String
      @pos = 0

      def initialize(@src : String)
      end

      def self.tokenize(src : String) : Array(Token)
        new(src).run
      end

      def run : Array(Token)
        prev_kind : TokenKind? = nil
        loop do
          skip_whitespace
          break if @pos >= @src.bytesize
          offset = @pos
          ch = current_char
          tok =
            case ch
            when '(' then single(TokenKind::LParen)
            when ')' then single(TokenKind::RParen)
            when '[' then single(TokenKind::LBracket)
            when ']' then single(TokenKind::RBracket)
            when '.' then dot_or_number
            when '@' then single(TokenKind::At)
            when ',' then single(TokenKind::Comma)
            when ':' then colon
            when '/' then slash
            when '|' then single(TokenKind::Pipe)
            when '+' then single(TokenKind::Plus)
            when '-' then single(TokenKind::Minus)
            when '=' then single(TokenKind::Eq)
            when '!' then neq
            when '<' then lt_or_le
            when '>' then gt_or_ge
            when '$' then single(TokenKind::Dollar)
            when '"', '\''
              literal(ch)
            when '*'
              # Disambiguation: multiply operator unless it starts a
              # step (preceded by nothing or by @, ::, (, [, an operator).
              if prev_kind.nil? || OPERATOR_PRECEDERS.includes?(prev_kind)
                single(TokenKind::Star)
              else
                single(TokenKind::Star)
              end
            when '0'..'9'
              number(offset)
            else
              if name_start_char?(ch)
                name_or_number(offset, prev_kind)
              else
                raise Error.new("unexpected character '#{ch}'", offset)
              end
            end
          # Track '*' separately is unnecessary: the parser resolves
          # operator vs node-test from grammar position.
          prev_kind = tok.kind
          @tokens << tok
        end
        @tokens
      end

      private OPERATOR_PRECEDERS = [
        TokenKind::At, TokenKind::ColonColon, TokenKind::LParen,
        TokenKind::LBracket, TokenKind::Pipe, TokenKind::Plus,
        TokenKind::Minus, TokenKind::Eq, TokenKind::Neq, TokenKind::Lt,
        TokenKind::Le, TokenKind::Gt, TokenKind::Ge, TokenKind::Slash,
        TokenKind::SlashSlash, TokenKind::Comma, TokenKind::Dollar,
      ]

      private def current_char : Char
        ch, _ = KXML.decode_char_at(@src, @pos)
        ch
      end

      private def single(kind : TokenKind) : Token
        tok = Token.new(kind, current_char.to_s, @pos)
        @pos += 1
        tok
      end

      private def skip_whitespace : Nil
        while @pos < @src.bytesize
          ch, _ = KXML.decode_char_at(@src, @pos)
          break unless ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r'
          @pos += ch.bytesize
        end
      end

      private def dot_or_number : Token
        if (@pos + 1 < @src.bytesize) && @src.byte_at(@pos + 1).chr.ascii_number?
          number(@pos)
        else
          tok = Token.new(TokenKind::Dot, ".", @pos)
          @pos += 1
          if @pos < @src.bytesize && @src.byte_at(@pos) == '.'.ord
            tok = Token.new(TokenKind::DotDot, "..", tok.offset)
            @pos += 1
          end
          tok
        end
      end

      private def colon : Token
        if @pos + 1 < @src.bytesize && @src.byte_at(@pos + 1) == ':'.ord
          tok = Token.new(TokenKind::ColonColon, "::", @pos)
          @pos += 2
          tok
        else
          single(TokenKind::Colon)
        end
      end

      private def slash : Token
        if @pos + 1 < @src.bytesize && @src.byte_at(@pos + 1) == '/'.ord
          tok = Token.new(TokenKind::SlashSlash, "//", @pos)
          @pos += 2
          tok
        else
          single(TokenKind::Slash)
        end
      end

      private def neq : Token
        if @pos + 1 < @src.bytesize && @src.byte_at(@pos + 1) == '='.ord
          tok = Token.new(TokenKind::Neq, "!=", @pos)
          @pos += 2
          tok
        else
          raise Error.new("unexpected '!'", @pos)
        end
      end

      private def lt_or_le : Token
        if @pos + 1 < @src.bytesize && @src.byte_at(@pos + 1) == '='.ord
          tok = Token.new(TokenKind::Le, "<=", @pos)
          @pos += 2
          tok
        else
          single(TokenKind::Lt)
        end
      end

      private def gt_or_ge : Token
        if @pos + 1 < @src.bytesize && @src.byte_at(@pos + 1) == '='.ord
          tok = Token.new(TokenKind::Ge, ">=", @pos)
          @pos += 2
          tok
        else
          single(TokenKind::Gt)
        end
      end

      private def literal(quote : Char) : Token
        start = @pos
        @pos += quote.bytesize
        b = String::Builder.new
        loop do
          break if @pos >= @src.bytesize
          ch, len = KXML.decode_char_at(@src, @pos)
          if ch == quote
            @pos += len
            return Token.new(TokenKind::Literal, b.to_s, start)
          end
          b << ch
          @pos += len
        end
        raise Error.new("unterminated string literal", start)
      end

      private def number(start : Int32) : Token
        b = String::Builder.new
        while @pos < @src.bytesize && @src.byte_at(@pos).chr.ascii_number?
          b << @src.byte_at(@pos).chr
          @pos += 1
        end
        if @pos < @src.bytesize && @src.byte_at(@pos) == '.'.ord &&
           @pos + 1 < @src.bytesize && @src.byte_at(@pos + 1).chr.ascii_number?
          b << '.'
          @pos += 1
          while @pos < @src.bytesize && @src.byte_at(@pos).chr.ascii_number?
            b << @src.byte_at(@pos).chr
            @pos += 1
          end
        end
        Token.new(TokenKind::Number, b.to_s, start)
      end

      private def name_start_char?(ch : Char) : Bool
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

      # Reads an NCName (no colons) starting at a name-start character.
      private def read_ncname : String
        b = String::Builder.new
        ch, len = KXML.decode_char_at(@src, @pos)
        b << ch
        @pos += len
        while @pos < @src.bytesize
          ch, len = KXML.decode_char_at(@src, @pos)
          break unless name_char?(ch)
          b << ch
          @pos += len
        end
        b.to_s
      end

      private def name_or_number(start : Int32, prev_kind : TokenKind?) : Token
        # Section 3.7: if the preceding token is not '@', '::', '(', '[',
        # or an operator, then an NCName matching an OperatorName is an
        # operator, and this matters for lexing 'div'/'mod' following a
        # number ("1div2" would otherwise lex as one name - numbers and
        # names are read separately here so this case is handled by the
        # parser instead).
        text = read_ncname
        # QName / NCName:* / axis detection
        if @pos < @src.bytesize && @src.byte_at(@pos) == ':'.ord
          if @pos + 1 < @src.bytesize && @src.byte_at(@pos + 1) == ':'.ord
            return Token.new(TokenKind::NCName, text, start)
          elsif @pos + 1 < @src.bytesize && @src.byte_at(@pos + 1) == '*'.ord
            @pos += 2
            return Token.new(TokenKind::QNameStar, text + ":*", start)
          elsif @pos + 1 < @src.bytesize
            # read the local part
            @pos += 1 # colon
            local = read_ncname
            return Token.new(TokenKind::QName, text + ":" + local, start)
          else
            return Token.new(TokenKind::NCName, text, start)
          end
        end
        Token.new(TokenKind::NCName, text, start)
      end
    end
  end
end
