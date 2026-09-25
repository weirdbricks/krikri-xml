require "./lexer"

module KXML
  module XPath
    # Axis names from section 2.2.
    AXES = %w[child descendant parent ancestor following-sibling
      preceding-sibling following preceding attribute namespace
      self descendant-or-self ancestor-or-self]

    NODE_TYPES = %w[node text comment processing-instruction]

    abstract class Expr
    end

    class OrExpr < Expr
      getter left : Expr
      getter right : Expr

      def initialize(@left, @right)
      end
    end

    class AndExpr < Expr
      getter left : Expr
      getter right : Expr

      def initialize(@left, @right)
      end
    end

    class EqExpr < Expr
      getter op : Symbol
      getter left : Expr
      getter right : Expr

      def initialize(@op, @left, @right)
      end
    end

    class RelExpr < Expr
      getter op : Symbol
      getter left : Expr
      getter right : Expr

      def initialize(@op, @left, @right)
      end
    end

    class AddExpr < Expr
      getter op : Symbol
      getter left : Expr
      getter right : Expr

      def initialize(@op, @left, @right)
      end
    end

    class MulExpr < Expr
      getter op : Symbol
      getter left : Expr
      getter right : Expr

      def initialize(@op, @left, @right)
      end
    end

    class NegExpr < Expr
      getter operand : Expr

      def initialize(@operand)
      end
    end

    class UnionExpr < Expr
      getter left : Expr
      getter right : Expr

      def initialize(@left, @right)
      end
    end

    abstract class PathBase < Expr
    end

    # A location path; absolute paths start at the document node.
    class PathExpr < PathBase
      getter? absolute : Bool
      getter steps : Array(Step)

      def initialize(@absolute : Bool, @steps : Array(Step))
      end
    end

    # FilterExpr (PrimaryExpr with predicates) optionally followed by
    # relative path steps.
    class FilterPathExpr < PathBase
      getter primary : Expr
      getter predicates : Array(Expr)
      getter steps : Array(Step)

      def initialize(@primary : Expr, @predicates : Array(Expr), @steps : Array(Step))
      end
    end

    struct Step
      getter axis : Symbol
      getter test : NodeTest
      getter predicates : Array(Expr)

      def initialize(@axis : Symbol, @test : NodeTest, @predicates : Array(Expr))
      end
    end

    abstract class NodeTest
    end

    class NameTest < NodeTest
      # prefix nil = unprefixed local name; local "*" = wildcard;
      # prefix "*" = any namespace.
      getter prefix : String?
      getter local : String

      def initialize(@prefix : String?, @local : String)
      end
    end

    class TypeTest < NodeTest
      getter type : Symbol
      getter arg : String?

      def initialize(@type : Symbol, @arg : String?)
      end
    end

    class FunctionCall < Expr
      getter name : String
      getter args : Array(Expr)

      def initialize(@name : String, @args : Array(Expr))
      end
    end

    class LiteralExpr < Expr
      getter value : String

      def initialize(@value : String)
      end
    end

    class NumberExpr < Expr
      getter value : Float64

      def initialize(@value : Float64)
      end
    end

    class VariableRef < Expr
      getter name : String

      def initialize(@name : String)
      end
    end

    class Parser
      @tokens : Array(Token)
      @idx = 0
      @src : String

      def initialize(@src : String)
        @tokens = Lexer.tokenize(@src)
      end

      def self.parse(src : String) : Expr
        new(src).parse
      end

      def parse : Expr
        expr = parse_or
        unless at_end?
          raise Error.new("unexpected token '#{current.text}'", current.offset)
        end
        expr
      end

      private def at_end? : Bool
        @idx >= @tokens.size
      end

      private def current : Token
        raise Error.new("unexpected end of expression", @src.bytesize) if at_end?
        @tokens[@idx]
      end

      private def peek(offset = 0) : Token?
        i = @idx + offset
        i < @tokens.size ? @tokens[i] : nil
      end

      private def advance : Token
        tok = current
        @idx += 1
        tok
      end

      private def error(message : String) : NoReturn
        raise Error.new(message, current.offset)
      end

      private def parse_or : Expr
        left = parse_and
        while !at_end? && current.kind == TokenKind::NCName && current.text == "or"
          advance
          right = parse_and
          left = OrExpr.new(left, right)
        end
        left
      end

      private def parse_and : Expr
        left = parse_equality
        while !at_end? && current.kind == TokenKind::NCName && current.text == "and"
          advance
          right = parse_equality
          left = AndExpr.new(left, right)
        end
        left
      end

      private def parse_equality : Expr
        left = parse_relational
        while !at_end? && (current.kind == TokenKind::Eq || current.kind == TokenKind::Neq)
          op = current.kind == TokenKind::Eq ? :eq : :neq
          advance
          right = parse_relational
          left = EqExpr.new(op, left, right)
        end
        left
      end

      private def parse_relational : Expr
        left = parse_additive
        while !at_end? && (current.kind == TokenKind::Lt || current.kind == TokenKind::Le ||
              current.kind == TokenKind::Gt || current.kind == TokenKind::Ge)
          op = case current.kind
               when TokenKind::Lt then :lt
               when TokenKind::Le then :le
               when TokenKind::Gt then :gt
               else                    :ge
               end
          advance
          right = parse_additive
          left = RelExpr.new(op, left, right)
        end
        left
      end

      private def parse_additive : Expr
        left = parse_multiplicative
        while !at_end? && (current.kind == TokenKind::Plus || current.kind == TokenKind::Minus)
          op = current.kind == TokenKind::Plus ? :add : :sub
          advance
          right = parse_multiplicative
          left = AddExpr.new(op, left, right)
        end
        left
      end

      private def parse_multiplicative : Expr
        left = parse_unary
        while !at_end?
          if current.kind == TokenKind::Star
            advance
            right = parse_unary
            left = MulExpr.new(:mul, left, right)
          elsif current.kind == TokenKind::NCName && (current.text == "div" || current.text == "mod")
            op = current.text == "div" ? :div : :mod
            advance
            right = parse_unary
            left = MulExpr.new(op, left, right)
          else
            break
          end
        end
        left
      end

      private def parse_unary : Expr
        if !at_end? && current.kind == TokenKind::Minus
          advance
          operand = parse_unary
          return NegExpr.new(operand)
        end
        parse_union
      end

      private def parse_union : Expr
        left = parse_path
        while !at_end? && current.kind == TokenKind::Pipe
          advance
          right = parse_path
          left = UnionExpr.new(left, right)
        end
        left
      end

      # PathExpr ::= LocationPath | FilterExpr (('/' | '//') RelativeLocationPath)?
      private def parse_path : Expr
        tok = current
        if tok.kind == TokenKind::Slash || tok.kind == TokenKind::SlashSlash
          # Both abbreviations start at the document node: '/' is the bare
          # absolute root step, and '//' abbreviates
          # /descendant-or-self::node()/ (section 2.5), so a leading '//' is
          # an absolute path even though its first token is not '/'.
          absolute = true
          advance
          steps = [] of Step
          # A leading '//' abbreviates /descendant-or-self::node()/
          if tok.kind == TokenKind::SlashSlash
            steps << Step.new(:descendant_or_self, TypeTest.new(:node, nil), [] of Expr)
            error("expected a node test after '//'") unless starts_step?
            steps.concat(parse_relative_location_path)
          elsif starts_step?
            steps.concat(parse_relative_location_path)
          else
            return PathExpr.new(absolute, steps) # bare '/'
          end
          return PathExpr.new(absolute, steps)
        end

        # FilterExpr start? A PrimaryExpr: literal, number, '(', $, or a
        # function call (NCName followed by '(' that is not a node type).
        if starts_primary?
          primary = parse_primary
          predicates = parse_predicates
          steps = [] of Step
          if !at_end? && (current.kind == TokenKind::Slash || current.kind == TokenKind::SlashSlash)
            advance
            steps.concat(parse_relative_location_path)
          end
          return primary if predicates.empty? && steps.empty?
          return FilterPathExpr.new(primary, predicates, steps)
        end

        PathExpr.new(false, parse_relative_location_path)
      end

      private def starts_primary? : Bool
        return false if at_end?
        case current.kind
        when TokenKind::Literal, TokenKind::Number, TokenKind::LParen, TokenKind::Dollar
          true
        when TokenKind::NCName
          nxt = peek(1)
          !nxt.nil? && nxt.kind == TokenKind::LParen &&
            !NODE_TYPES.includes?(current.text)
        else
          false
        end
      end

      private def starts_step? : Bool
        return false if at_end?
        case current.kind
        when TokenKind::Dot, TokenKind::DotDot, TokenKind::At, TokenKind::Star,
             TokenKind::QName, TokenKind::QNameStar
          true
        when TokenKind::NCName
          nxt = peek(1)
          if nxt.nil?
            true
          elsif nxt.kind == TokenKind::ColonColon
            AXES.includes?(current.text)
          elsif nxt.kind == TokenKind::LParen && NODE_TYPES.includes?(current.text)
            true
          else
            true
          end
        else
          false
        end
      end

      private def parse_relative_location_path : Array(Step)
        steps = [parse_step]
        while !at_end? && (current.kind == TokenKind::Slash || current.kind == TokenKind::SlashSlash)
          descendant = current.kind == TokenKind::SlashSlash
          advance
          if descendant
            dot = Step.new(:descendant_or_self, TypeTest.new(:node, nil), [] of Expr)
            steps << dot
          end
          steps << parse_step
        end
        steps
      end

      private def parse_predicates : Array(Expr)
        preds = [] of Expr
        while !at_end? && current.kind == TokenKind::LBracket
          advance
          e = parse_or
          expect(TokenKind::RBracket, "']'")
          preds << e
        end
        preds
      end

      private def parse_step : Step
        axis : Symbol = :child
        # Abbreviated steps
        if current.kind == TokenKind::Dot
          advance
          return Step.new(:self, TypeTest.new(:node, nil), parse_predicates)
        elsif current.kind == TokenKind::DotDot
          advance
          return Step.new(:parent, TypeTest.new(:node, nil), parse_predicates)
        end

        if current.kind == TokenKind::At
          advance
          axis = :attribute
        elsif current.kind == TokenKind::NCName && (nxt = peek(1)) && nxt.kind == TokenKind::ColonColon
          axis = normalize_axis(current.text)
          advance
          advance
        end

        test = parse_node_test(axis)
        preds = parse_predicates
        Step.new(axis, test, preds)
      end

      private def normalize_axis(name : String) : Symbol
        case name
        when "child"              then :child
        when "descendant"         then :descendant
        when "parent"             then :parent
        when "ancestor"           then :ancestor
        when "following-sibling"  then :following_sibling
        when "preceding-sibling"  then :preceding_sibling
        when "following"          then :following
        when "preceding"          then :preceding
        when "attribute"          then :attribute
        when "namespace"          then :namespace
        when "self"               then :self
        when "descendant-or-self" then :descendant_or_self
        when "ancestor-or-self"   then :ancestor_or_self
        else
          error("unknown axis '#{name}'")
        end
      end

      private def parse_node_test(axis : Symbol) : NodeTest
        case current.kind
        when TokenKind::Star
          advance
          NameTest.new(nil, "*")
        when TokenKind::QNameStar
          tok = advance
          NameTest.new(tok.text.rpartition(':')[0], "*")
        when TokenKind::QName
          tok = advance
          prefix, local = tok.text.split(':', 2)
          NameTest.new(prefix, local)
        when TokenKind::NCName
          if (nxt = peek(1)) && nxt.kind == TokenKind::LParen && NODE_TYPES.includes?(current.text)
            type_name = current.text
            advance
            advance
            arg : String? = nil
            if type_name == "processing-instruction" && current.kind == TokenKind::Literal
              arg = advance.text
            end
            expect(TokenKind::RParen, "')'")
            type = case type_name
                   when "node"    then :node
                   when "text"    then :text
                   when "comment" then :comment
                   else                :processing_instruction
                   end
            return TypeTest.new(type, arg)
          end
          tok = advance
          NameTest.new(nil, tok.text)
        else
          error("expected a node test")
        end
      end

      private def parse_primary : Expr
        case current.kind
        when TokenKind::Literal
          LiteralExpr.new(advance.text)
        when TokenKind::Number
          NumberExpr.new(advance.number_value)
        when TokenKind::LParen
          advance
          e = parse_or
          expect(TokenKind::RParen, "')'")
          e
        when TokenKind::Dollar
          offset = current.offset
          advance
          if current.kind == TokenKind::NCName
            VariableRef.new(advance.text)
          else
            raise Error.new("expected a variable name after '$'", offset)
          end
        when TokenKind::NCName
          name = advance.text
          expect(TokenKind::LParen, "'(' after a function name")
          args = [] of Expr
          if current.kind != TokenKind::RParen
            args << parse_or
            while current.kind == TokenKind::Comma
              advance
              args << parse_or
            end
          end
          expect(TokenKind::RParen, "')'")
          FunctionCall.new(name, args)
        else
          error("expected a primary expression")
        end
      end

      private def expect(kind : TokenKind, what : String) : Nil
        if at_end? || current.kind != kind
          raise Error.new("expected #{what}", at_end? ? @src.bytesize : current.offset)
        end
        advance
      end
    end
  end
end
