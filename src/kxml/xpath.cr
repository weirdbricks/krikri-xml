require "./xpath/base"
require "./xpath/lexer"
require "./xpath/parser"
require "./xpath/evaluator"

module KXML
  # XPath 1.0 evaluation over the KXML DOM, implemented per W3C
  # REC-xpath-19991116.
  module XPath
    # Evaluates *expr* with *context* as the context node. *vars* binds
    # `$name` variable references to XPath values; *ns_map* resolves
    # expression prefixes exclusively (instead of in-scope declarations).
    # The namespace axis works via synthesized namespace nodes and id()
    # resolves ID attributes declared in the internal DTD subset.
    def self.evaluate(expr : String, context : Node | Attribute, position : Int32 = 1, size : Int32 = 1,
                      ns_map : Hash(String, String)? = nil, vars : Hash(String, Value)? = nil) : Value
      Evaluator.evaluate(expr, context, position, size, ns_map, vars)
    end

    # Like `evaluate` but requires a node-set result.
    def self.evaluate_nodes(expr : String, context : Node | Attribute, position : Int32 = 1, size : Int32 = 1,
                            ns_map : Hash(String, String)? = nil, vars : Hash(String, Value)? = nil) : NodeSet
      v = evaluate(expr, context, position, size, ns_map, vars)
      raise Error.new("expression did not evaluate to a node-set", 0) unless v.is_a?(NodeSet)
      v
    end
  end
end
