require "../nodes"

module KXML
  module XPath
    class Error < ::Exception
      getter offset : Int32

      def initialize(message : String, @offset : Int32)
        super("#{message} (at character #{@offset})")
      end
    end

    # A node-set is a document-ordered, duplicate-free list of nodes;
    # attribute nodes participate as first-class values.
    alias NodeSet = Array(Node | Attribute)

    alias Value = NodeSet | String | Float64 | Bool

    # Section 5: string-values.
    def self.string_value(node : Node | Attribute) : String
      case node
      when Attribute
        node.value
      when Text, CData
        node.content
      when Comment
        node.content
      when ProcessingInstruction
        node.content
      when Element
        String.build do |b|
          append_text_descendants(node, b)
        end
      when Document
        if r = node.root
          String.build do |b|
            append_text_descendants(r, b)
          end
        else
          ""
        end
      else
        ""
      end
    end

    private def self.append_text_descendants(node : Node, b : String::Builder) : Nil
      node.children.each do |child|
        case child
        when Text, CData
          b << child.content
        when Element
          append_text_descendants(child, b)
        end
      end
    end

    # Section 5.1: document order is the parser-assigned order number.
    def self.order_of(node : Node | Attribute) : Int32
      node.doc_order
    end

    def self.sort_nodes(nodes : Enumerable(Node | Attribute)) : NodeSet
      nodes.to_a.uniq.sort_by! { |node| order_of(node) }
    end

    # Section 4.2: the local part of an expanded name; empty for the other
    # node kinds.
    def self.local_name_of(node : Node | Attribute) : String
      case node
      when Attribute
        node.local_name
      when Element
        node.local_name
      when ProcessingInstruction
        node.target
      else
        ""
      end
    end

    def self.expanded_name_of(node : Node | Attribute) : String
      case node
      when Attribute, Element
        node.name
      when ProcessingInstruction
        node.target
      else
        ""
      end
    end

    def self.namespace_uri_of(node : Node | Attribute) : String?
      case node
      when Attribute, Element then node.namespace_uri
      end
    end

    # Section 3.5 string(number) conversion.
    def self.number_to_string(n : Float64) : String
      if n.nan?
        "NaN"
      elsif n.infinite?
        n > 0 ? "Infinity" : "-Infinity"
      elsif n == n.trunc
        # integral value (also handles -0.0 -> "0")
        int = n.trunc.to_i
        int.to_s
      else
        n.to_s
      end
    end

    # Section 4.3 number(string): optional whitespace, optional '-', then
    # digits with at most one '.'; no exponent notation in XPath 1.0.
    def self.string_to_number(s : String) : Float64
      t = strip_xml_whitespace(s)
      return Float64::NAN if t.empty?
      i = 0
      negative = false
      if t[0] == '-'
        negative = true
        i = 1
      end
      int_digits = 0
      while i < t.size && t.char_at(i).ascii_number?
        int_digits += 1
        i += 1
      end
      frac_digits = 0
      if i < t.size && t.char_at(i) == '.'
        i += 1
        while i < t.size && t.char_at(i).ascii_number?
          frac_digits += 1
          i += 1
        end
      end
      return Float64::NAN unless i == t.size
      return Float64::NAN if int_digits == 0 && frac_digits == 0
      value = t[negative ? 1 : 0, t.size - (negative ? 1 : 0)].to_f
      negative ? -value : value
    end

    def self.strip_xml_whitespace(s : String) : String
      ws = " \t\n\r"
      s.lstrip(ws).rstrip(ws)
    end

    # XPath round(): closest integer, ties toward positive infinity;
    # NaN and infinities pass through.
    def self.xpath_round(x : Float64) : Float64
      return x if x.nan? || x.infinite?
      (x + 0.5).floor.to_f
    end
  end
end
