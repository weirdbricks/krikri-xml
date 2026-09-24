require "./xpath/base"
require "./xpath/lexer"
require "./xpath/parser"
require "./xpath/evaluator"

module KXML
  # XPath 1.0 evaluation over the KXML DOM, implemented per W3C
  # REC-xpath-19991116.
  module XPath
    # Evaluates *expr* with *context* as the context node.
    #
    # Deliberate limitations, raised as `XPath::Error`:
    # - variable references ($x) are not supported (no binding mechanism),
    # - the namespace axis is not supported (the DOM has no namespace nodes),
    # - id() is not supported (requires DTD ID information).
    def self.evaluate(expr : String, context : Node | Attribute, position : Int32 = 1, size : Int32 = 1) : Value
      Evaluator.evaluate(expr, context, position, size)
    end

    # Like `evaluate` but requires a node-set result.
    def self.evaluate_nodes(expr : String, context : Node | Attribute, position : Int32 = 1, size : Int32 = 1) : NodeSet
      v = evaluate(expr, context, position, size)
      raise Error.new("expression did not evaluate to a node-set", 0) unless v.is_a?(NodeSet)
      v
    end
  end
end
