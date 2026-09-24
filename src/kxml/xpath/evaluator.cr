require "./parser"

module KXML
  module XPath
    # Evaluator for XPath 1.0 expressions against a KXML DOM.
    class Evaluator
      @expr : Expr
      @ns_map : Hash(String, String)?

      def initialize(@expr : Expr, @ns_map = nil)
      end

      def self.evaluate(expr : String, context : Node | Attribute, position : Int32 = 1, size : Int32 = 1,
                        ns_map : Hash(String, String)? = nil) : Value
        new(Parser.parse(expr), ns_map).eval(context, position, size)
      end

      def eval(context : Node | Attribute, position : Int32, size : Int32) : Value
        eval_expr(@expr, Context.new(context, position, size))
      end

      private struct Context
        getter node : Node | Attribute
        getter position : Int32
        getter size : Int32

        def initialize(@node : Node | Attribute, @position : Int32, @size : Int32)
        end
      end

      # ------------------------------------------------------------------
      # expression dispatch

      private def eval_expr(e : Expr, ctx : Context) : Value
        case e
        when OrExpr
          l = to_bool(eval_expr(e.left, ctx))
          return true if l
          to_bool(eval_expr(e.right, ctx))
        when AndExpr
          l = to_bool(eval_expr(e.left, ctx))
          return false unless l
          to_bool(eval_expr(e.right, ctx))
        when EqExpr
          compare(e.op, eval_expr(e.left, ctx), eval_expr(e.right, ctx))
        when RelExpr
          compare(e.op, eval_expr(e.left, ctx), eval_expr(e.right, ctx))
        when AddExpr
          case e.op
          when :add then to_number(eval_expr(e.left, ctx)) + to_number(eval_expr(e.right, ctx))
          when :sub then to_number(eval_expr(e.left, ctx)) - to_number(eval_expr(e.right, ctx))
          else           raise Error.new("bug: unknown add op", 0)
          end
        when MulExpr
          l = to_number(eval_expr(e.left, ctx))
          r = to_number(eval_expr(e.right, ctx))
          case e.op
          when :mul then l * r
          when :div then l / r # IEEE: x/0 = +/-Infinity, 0/0 = NaN
          when :mod then r == 0.0 ? Float64::NAN : l - r * (l / r).trunc
          else           raise Error.new("bug: unknown mul op", 0)
          end
        when NegExpr
          -to_number(eval_expr(e.operand, ctx))
        when UnionExpr
          l = eval_expr(e.left, ctx)
          r = eval_expr(e.right, ctx)
          unless l.is_a?(NodeSet) && r.is_a?(NodeSet)
            raise Error.new("'|' requires node-set operands", 0)
          end
          XPath.sort_nodes(l + r)
        when PathExpr
          eval_path(e, ctx)
        when FilterPathExpr
          eval_filter_path(e, ctx)
        when LiteralExpr
          e.value
        when NumberExpr
          e.value
        when VariableRef
          raise Error.new("variables are not supported ($#{e.name})", 0)
        when FunctionCall
          call_function(e, ctx)
        else
          raise Error.new("bug: unknown expression", 0)
        end
      end

      # ------------------------------------------------------------------
      # location paths

      private def eval_path(e : PathExpr, ctx : Context) : NodeSet
        if e.absolute?
          nodes = NodeSet{context_document(ctx.node)}
        else
          nodes = NodeSet{ctx.node}
        end
        e.steps.each do |step|
          nodes = eval_step(step, nodes)
          return NodeSet.new if nodes.empty?
        end
        nodes
      end

      private def eval_filter_path(e : FilterPathExpr, ctx : Context) : NodeSet
        v = eval_expr(e.primary, ctx)
        raise Error.new("predicates require a node-set", 0) unless v.is_a?(NodeSet)
        nodes = apply_predicates(v, e.predicates, true)
        e.steps.each do |step|
          nodes = eval_step(step, nodes)
          return NodeSet.new if nodes.empty?
        end
        nodes
      end

      private def context_document(node : Node | Attribute) : Document
        if node.is_a?(Document)
          node
        elsif node.is_a?(Attribute)
          raise Error.new("no document for attribute context", 0)
        elsif d = node.document
          d
        else
          raise Error.new("no document for context node", 0)
        end
      end

      private def eval_step(step : Step, contexts : NodeSet) : NodeSet
        results = NodeSet.new
        contexts.each do |ctx_node|
          # Only document and element nodes can have axis members other
          # than self; other node kinds yield empty sets for most axes.
          list = axis_nodes(step.axis, ctx_node)
          list = apply_node_test(list, step.test, step.axis, ctx_node)
          results.concat(list)
        end
        results = apply_predicates(results, step.predicates, REVERSE_AXES.includes?(step.axis))
        XPath.sort_nodes(results)
      end

      REVERSE_AXES = [:ancestor, :ancestor_or_self, :preceding, :preceding_sibling]

      private def axis_nodes(axis : Symbol, node : Node | Attribute) : NodeSet
        if node.is_a?(Attribute)
          # Attribute nodes have no children; only the self axis applies.
          return axis == :self ? NodeSet{node} : NodeSet.new
        end
        case axis
        when :child
          node.is_a?(Document) || node.is_a?(Element) ? node.children.map(&.as(Node | Attribute)).to_a : NodeSet.new
        when :descendant
          descendants(node, false)
        when :parent
          node.parent_node ? NodeSet{node.parent_node.as(Node)} : NodeSet.new
        when :ancestor
          ancestors(node, false)
        when :attribute
          node.is_a?(Element) ? node.attributes.map { |attr| attr.as(Node | Attribute) }.to_a : NodeSet.new
        when :self
          NodeSet{node}
        when :following_sibling
          siblings(node, false)
        when :preceding_sibling
          siblings(node, true)
        when :following
          following(node)
        when :preceding
          preceding(node)
        when :descendant_or_self
          descendants(node, true)
        when :ancestor_or_self
          ancestors(node, true)
        when :namespace
          raise Error.new("the namespace axis is not supported", 0)
        else
          raise Error.new("bug: unknown axis", 0)
        end
      end

      private def descendants(node : Node, include_self : Bool) : NodeSet
        out = NodeSet.new
        out << node if include_self
        stack = node.is_a?(Document) || node.is_a?(Element) ? node.children.to_a.reverse : [] of Node
        until stack.empty?
          n = stack.pop
          out << n
          if n.is_a?(Document) || n.is_a?(Element)
            n.children.to_a.reverse.each { |child| stack.push(child) }
          end
        end
        out
      end

      private def ancestors(node : Node, include_self : Bool) : NodeSet
        out = NodeSet.new
        out << node if include_self
        n = node.parent_node
        while n
          out << n
          n = n.parent_node
        end
        out
      end

      private def siblings(node : Node | Attribute, reverse : Bool) : NodeSet
        parent = node.parent_node
        return NodeSet.new unless parent
        sibs = parent.is_a?(Document) || parent.is_a?(Element) ? parent.children : NodeSet.new
        out = NodeSet.new
        before = true
        sibs.each do |sibling|
          before = false if sibling.object_id == node.object_id
          out << sibling if before
        end
        reverse ? out.reverse : out
      end

      private def all_document_nodes(node : Node | Attribute) : NodeSet
        doc = node.is_a?(Document) ? node : (node.is_a?(Attribute) ? nil : node.document)
        return NodeSet.new unless doc
        descendants(doc, true)
      end

      private def following(node : Node | Attribute) : NodeSet
        # All nodes after the context node in document order, excluding
        # descendants; attribute and namespace nodes are excluded.
        all = all_document_nodes(node)
        out = NodeSet.new
        all.each do |candidate|
          next unless XPath.order_of(candidate) > XPath.order_of(node)
          next if (node.is_a?(Node)) && descendant_or_self?(node, candidate.as(Node))
          out << candidate
        end
        out
      end

      private def preceding(node : Node | Attribute) : NodeSet
        all = all_document_nodes(node)
        ancestor_set = Set(Node).new
        ancestor = node.is_a?(Node) ? node.parent_node : nil
        while ancestor
          ancestor_set << ancestor
          ancestor = ancestor.parent_node
        end
        out = NodeSet.new
        all.each do |candidate|
          next unless XPath.order_of(candidate) < XPath.order_of(node)
          next if ancestor_set.includes?(candidate)
          out << candidate
        end
        out.reverse
      end

      private def descendant_or_self?(ancestor : Node, node : Node) : Bool
        return true if node.object_id == ancestor.object_id
        n = node.parent_node
        while n
          return true if n.object_id == ancestor.object_id
          n = n.parent_node
        end
        false
      end

      # ------------------------------------------------------------------
      # node tests

      private def apply_node_test(nodes : NodeSet, test : NodeTest, axis : Symbol, ctx_node : Node | Attribute) : NodeSet
        case test
        when TypeTest
          nodes.select do |candidate|
            case test.type
            when :node    then true
            when :text    then candidate.is_a?(Text) || candidate.is_a?(CData)
            when :comment then candidate.is_a?(Comment)
            when :processing_instruction
              candidate.is_a?(ProcessingInstruction) && (test.arg.nil? || test.arg == candidate.target)
            else
              false
            end
          end
        when NameTest
          principal = axis == :attribute
          uri = resolve_test_uri(test, ctx_node, principal)
          nodes.select do |candidate|
            match_name_test(candidate, test, uri, principal)
          end
        else
          raise Error.new("bug: unknown node test", 0)
        end
      end

      private def match_name_test(n : Node | Attribute, test : NameTest, uri : String, principal : Bool) : Bool
        if principal
          return false unless n.is_a?(Attribute)
        else
          return false unless n.is_a?(Element)
        end
        node_uri = XPath.namespace_uri_of(n) || ""
        if test.prefix.nil?
          test.local == "*" ? true : (node_uri == uri && XPath.local_name_of(n) == test.local)
        elsif test.prefix == "*"
          return XPath.local_name_of(n) == test.local unless test.local == "*"
          true
        else
          return false unless node_uri == uri
          XPath.local_name_of(n) == test.local
        end
      end

      # Resolves the namespace URI implied by a name test on the given
      # axis: the in-scope namespaces of the context node, where an
      # unprefixed name test uses the default namespace (or no namespace).
      private def resolve_test_uri(test : NameTest, ctx_node : Node | Attribute, principal : Bool) : String
        # libxml2 mode (an explicit namespace map was passed): prefixes
        # resolve exclusively from the map and unprefixed name tests match
        # only no-namespace nodes (libxml2 XPath has no default-namespace
        # concept).
        if ns_map = @ns_map
          return "" if principal || test.prefix == "*" || ctx_node.is_a?(Attribute)
          return "" if test.prefix.nil?
          return ns_map[test.prefix]? || ""
        end
        # Unprefixed name tests use the in-scope default namespace - except
        # on the attribute axis, where unprefixed attributes have no
        # namespace regardless of the default.
        if test.prefix.nil?
          return "" if principal
          ns = ctx_node.is_a?(Node) ? in_scope_namespaces(ctx_node) : Hash(String, String).new
          return ns[""]? || ""
        end
        return "" if test.prefix == "*" || ctx_node.is_a?(Attribute)
        in_scope_namespaces(ctx_node)[test.prefix]? || ""
      end

      # In-scope namespaces of *node*: xmlns/xmlns:* attributes collected
      # from the nearest element upward (nearer bindings win).
      private def in_scope_namespaces(node : Node) : Hash(String, String)
        chain = [] of Element
        n : Node? = node
        while n
          chain << n if n.is_a?(Element)
          n = n.parent_node
        end
        ns = Hash(String, String).new
        chain.reverse_each do |element|
          element.attributes.each do |attr|
            if attr.prefix == "xmlns"
              ns[attr.local_name] = attr.value
            elsif attr.prefix.nil? && attr.local_name == "xmlns"
              if !attr.value.empty?
                ns[""] = attr.value
              else
                ns.delete("")
              end
            end
          end
        end
        ns
      end

      # ------------------------------------------------------------------
      # predicates

      private def apply_predicates(nodes : NodeSet, predicates : Array(Expr), reverse : Bool) : NodeSet
        predicates.each do |pred|
          size = nodes.size
          kept = NodeSet.new
          nodes.each_with_index do |node, index|
            pos = reverse ? size - index : index + 1
            v = eval_expr(pred, Context.new(node, pos, size))
            case v
            when NodeSet
              kept << node unless v.empty?
            when Float64
              kept << node if pos == v
            when Bool
              kept << node if v
            when String
              kept << node if to_bool(v)
            end
          end
          nodes = kept
        end
        nodes
      end

      # ------------------------------------------------------------------
      # comparisons (section 3.4)

      private def compare(op : Symbol, l : Value, r : Value) : Bool
        case op
        when :eq  then equality(true, l, r)
        when :neq then equality(false, l, r)
        else           relational(op, l, r)
        end
      end

      private def equality(plain_eq : Bool, l : Value, r : Value) : Bool
        if l.is_a?(NodeSet) && r.is_a?(NodeSet)
          if plain_eq
            l.any? { |a| r.any? { |b| XPath.string_value(a) == XPath.string_value(b) } }
          else
            l.any? { |a| r.any? { |b| XPath.string_value(a) != XPath.string_value(b) } }
          end
        elsif l.is_a?(NodeSet)
          node_set_equality(plain_eq, l, r)
        elsif r.is_a?(NodeSet)
          node_set_equality(plain_eq, r, l)
        else
          basic_equality(plain_eq, l, r)
        end
      end

      private def node_set_equality(plain_eq : Bool, nodes : NodeSet, other : Value) : Bool
        case other
        when Bool
          b = to_bool(nodes)
          plain_eq ? b == other : b != other
        when Float64
          nodes.any? { |node| (XPath.string_to_number(XPath.string_value(node)) == other) == plain_eq }
        else
          nodes.any? { |node| (XPath.string_value(node) == other.as(String)) == plain_eq }
        end
      end

      private def basic_equality(plain_eq : Bool, l : Value, r : Value) : Bool
        if l.is_a?(Bool) || r.is_a?(Bool)
          lb = to_bool(l)
          rb = to_bool(r)
          plain_eq ? lb == rb : lb != rb
        elsif l.is_a?(Float64) || r.is_a?(Float64)
          ln = to_number(l)
          rn = to_number(r)
          if ln.nan? || rn.nan?
            plain_eq ? false : true
          else
            plain_eq ? ln == rn : ln != rn
          end
        else
          ls = l.as(String)
          rs = r.as(String)
          plain_eq ? ls == rs : ls != rs
        end
      end

      private def relational(op : Symbol, l : Value, r : Value) : Bool
        ln = l.is_a?(NodeSet) ? nil : to_number(l)
        rn = r.is_a?(NodeSet) ? nil : to_number(r)
        if l.is_a?(NodeSet) && r.is_a?(NodeSet)
          l.any? do |left_node|
            an = XPath.string_to_number(XPath.string_value(left_node))
            r.any? do |right_node|
              bn = XPath.string_to_number(XPath.string_value(right_node))
              num_rel(op, an, bn)
            end
          end
        elsif l.is_a?(NodeSet)
          # node-set rel number/string: compare numbers of string-values
          l.any? do |left_node|
            an = XPath.string_to_number(XPath.string_value(left_node))
            num_rel(op, an, rn.as(Float64))
          end
        elsif r.is_a?(NodeSet)
          r.any? do |right_node|
            bn = XPath.string_to_number(XPath.string_value(right_node))
            num_rel(op, ln.as(Float64), bn)
          end
        else
          num_rel(op, ln.as(Float64), rn.as(Float64))
        end
      end

      private def num_rel(op : Symbol, a : Float64, b : Float64) : Bool
        return false if a.nan? || b.nan?
        case op
        when :lt then a < b
        when :le then a <= b
        when :gt then a > b
        when :ge then a >= b
        else          false
        end
      end

      # ------------------------------------------------------------------
      # conversions (sections 3.5-3.7)

      private def to_bool(v : Value) : Bool
        case v
        when NodeSet then !v.empty?
        when Bool    then v
        when Float64 then !(v.nan? || v == 0.0)
        when String  then !v.empty?
        else              false
        end
      end

      private def to_number(v : Value) : Float64
        case v
        when NodeSet
          XPath.string_to_number(to_string(v))
        when Bool
          v ? 1.0 : 0.0
        when Float64
          v
        when String
          XPath.string_to_number(v)
        else
          Float64::NAN
        end
      end

      private def to_string(v : Value) : String
        case v
        when NodeSet
          v.empty? ? "" : XPath.string_value(v.first)
        when Bool
          v ? "true" : "false"
        when Float64
          XPath.number_to_string(v)
        when String
          v
        else
          ""
        end
      end

      # ------------------------------------------------------------------
      # core function library (section 4)

      private def call_function(e : FunctionCall, ctx : Context) : Value
        args = [] of Value
        e.args.each { |a| args << eval_expr(a, ctx) }
        case e.name
        when "last"
          check_arity(e, args, 0)
          ctx.size.to_f
        when "position"
          check_arity(e, args, 0)
          ctx.position.to_f
        when "count"
          check_arity(e, args, 1)
          arg = args[0]
          raise Error.new("count() requires a node-set", 0) unless arg.is_a?(NodeSet)
          arg.size.to_f
        when "id"
          raise Error.new("id() is not supported (requires DTD ID information)", 0)
        when "local-name", "name", "namespace-uri"
          check_arity(e, args, 0, 1)
          if args.empty?
            target = ctx.node
          else
            raise Error.new("#{e.name}() requires a node-set", 0) unless args[0].is_a?(NodeSet)
            nodes = args[0].as(NodeSet)
            target = nodes.first? # empty node-set -> empty string below
          end
          case e.name
          when "local-name" then target ? XPath.local_name_of(target) : ""
          when "name"       then target ? XPath.expanded_name_of(target) : ""
          else                   target ? (XPath.namespace_uri_of(target) || "") : ""
          end
        when "string"
          check_arity(e, args, 0, 1)
          args.empty? ? to_string(NodeSet{ctx.node}) : to_string(args[0])
        when "concat"
          raise Error.new("concat() requires at least two arguments", 0) if args.size < 2
          String.build do |b|
            args.each { |a| b << to_string(a) }
          end
        when "starts-with"
          check_arity(e, args, 2)
          to_string(args[0]).starts_with?(to_string(args[1]))
        when "contains"
          check_arity(e, args, 2)
          to_string(args[0]).includes?(to_string(args[1]))
        when "substring-before"
          check_arity(e, args, 2)
          s = to_string(args[0])
          t = to_string(args[1])
          idx = s.index(t)
          idx ? s[0...idx] : ""
        when "substring-after"
          check_arity(e, args, 2)
          s = to_string(args[0])
          t = to_string(args[1])
          idx = s.index(t)
          idx ? s[(idx + t.size)..] : ""
        when "substring"
          check_arity(e, args, 2, 3)
          substring_fn(to_string(args[0]), to_number(args[1]), args.size == 3 ? to_number(args[2]) : nil)
        when "string-length"
          check_arity(e, args, 0, 1)
          s = args.empty? ? to_string(NodeSet{ctx.node}) : to_string(args[0])
          s.size.to_f
        when "normalize-space"
          check_arity(e, args, 0, 1)
          s = args.empty? ? to_string(NodeSet{ctx.node}) : to_string(args[0])
          s.split(/[ \t\r\n]+/).reject(&.empty?).join(' ')
        when "translate"
          check_arity(e, args, 3)
          translate_fn(to_string(args[0]), to_string(args[1]), to_string(args[2]))
        when "boolean"
          check_arity(e, args, 1)
          to_bool(args[0])
        when "not"
          check_arity(e, args, 1)
          !to_bool(args[0])
        when "true"
          check_arity(e, args, 0)
          true
        when "false"
          check_arity(e, args, 0)
          false
        when "lang"
          check_arity(e, args, 1)
          lang_fn(ctx.node, to_string(args[0]))
        when "number"
          check_arity(e, args, 0, 1)
          args.empty? ? to_number(NodeSet{ctx.node}) : to_number(args[0])
        when "sum"
          check_arity(e, args, 1)
          arg = args[0]
          raise Error.new("sum() requires a node-set", 0) unless arg.is_a?(NodeSet)
          arg.sum { |node| XPath.string_to_number(XPath.string_value(node)) }
        when "floor"
          check_arity(e, args, 1)
          n = to_number(args[0])
          n.nan? || n.infinite? ? n : n.floor
        when "ceiling"
          check_arity(e, args, 1)
          n = to_number(args[0])
          n.nan? || n.infinite? ? n : n.ceil
        when "round"
          check_arity(e, args, 1)
          XPath.xpath_round(to_number(args[0]))
        else
          raise Error.new("unknown function '#{e.name}()'", 0)
        end
      end

      private def check_arity(e : FunctionCall, args : Array(Value), min : Int32, max : Int32? = nil) : Nil
        ok = args.size >= min && (max.nil? ? true : args.size <= max.as(Int32))
        return if ok
        raise Error.new("wrong number of arguments for #{e.name}()", 0)
      end

      # substring() per section 4.2, with its IEEE edge cases.
      private def substring_fn(s : String, start : Float64, len : Float64?) : String
        p = XPath.xpath_round(start)
        if len.nil?
          end_pos = Float64::INFINITY
        else
          l = XPath.xpath_round(len)
          if p.infinite? && l.infinite? && (p < 0)
            end_pos = Float64::INFINITY
          elsif p.nan? || l.nan?
            return ""
          else
            end_pos = p + l
          end
        end
        return "" if p.nan? || end_pos.nan?
        chars = s.chars
        out = String::Builder.new
        chars.each_with_index do |char, index|
          pos = index + 1
          out << char if pos >= p && pos < end_pos
        end
        out.to_s
      end

      private def translate_fn(s : String, from : String, to : String) : String
        map = Hash(Char, Char).new
        from.chars.each_with_index do |char, index|
          next if map.has_key?(char)
          replacement = index < to.size ? to.chars[index] : nil
          map[char] = replacement if replacement
        end
        String.build do |builder|
          s.each_char do |char|
            if replacement = map[char]?
              builder << replacement
            else
              builder << char unless from.includes?(char)
            end
          end
        end
      end

      private def lang_fn(node : Node | Attribute, requested : String) : Bool
        n : Node? = node.is_a?(Node) ? node : nil
        while n
          if n.is_a?(Element)
            if attr = n.attribute("xml:lang")
              have = attr.value.downcase
              want = requested.downcase
              return true if have == want
              return true if want.size < have.size && have.starts_with?(want) && have[want.size] == '-'
              return false
            end
          end
          n = n.parent_node
        end
        false
      end
    end
  end
end
