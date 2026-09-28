require "./spec_helper"

# Data-driven XPath 1.0 corpus: every case is a row in a table, evaluated
# against one shared fixture. Node-set expectations are described as exact
# node strings ("elem: <name> in <uri>", "@attr=value", "text: ...", ...),
# so adding coverage is adding rows, not code.
#
# Each row is a literal 6-tuple: the describe block below iterates the
# table at compile time to generate one test method per row (minitest's
# `it` is a compile-time method, so the table cannot be walked at runtime
# to register tests).

CORPUS_FIXTURE = <<-XML
  <?xml version="1.0"?>
  <!DOCTYPE r [
    <!ELEMENT r ANY>
    <!ATTLIST item id ID #IMPLIED>
    <!ENTITY greet "Hello">
  ]>
  <r xmlns:p="urn:p" xml:lang="en"><p:item id="i1" rank="1"><name>A</name><val>10</val><!--c1--></p:item><item id="i2" rank="2"><name>B</name><val>20</val><sub/></item><item rank="3"><name>C</name><val>30</val><sub/><sub/></item><meta><![CDATA[raw]]>tail</meta><?pi-target the-data?></r>
  XML

# Human-readable, exact description of an XPath node value.
def describe_node(node : KXML::Node | KXML::Attribute) : String
  case node
  when KXML::Document
    "doc"
  when KXML::NamespaceNode
    "ns:#{node.href}"
  when KXML::Attribute
    "@#{node.name}=#{node.value}"
  when KXML::Element
    uri = node.namespace_uri
    uri && !uri.empty? ? "elem:{#{uri}}#{node.name}" : "elem:#{node.name}"
  when KXML::Text
    "text:#{node.content}"
  when KXML::CData
    "text:#{node.content}"
  when KXML::Comment
    "comment:#{node.content}"
  when KXML::ProcessingInstruction
    "pi:#{node.target}:#{node.content}"
  else
    raise "unhandled node class #{node.class}"
  end
end

def resolve(expr : String, ctx : KXML::Node | KXML::Attribute) : KXML::Node | KXML::Attribute
  return ctx if expr == "."
  nodes = KXML::XPath.evaluate_nodes(expr, ctx)
  raise "context expression '#{expr}' selected #{nodes.size} nodes" unless nodes.size == 1
  nodes[0]
end

# Each case:
#   c("expr", kind, expected, ctx_expr: nil, ns_map: nil, vars: nil)
# kind is one of "nodes", "string", "number", "bool", "error".
# ctx_expr selects the context node from the fixture root (nil = root);
# for node expectations the strings are compared to describe_node output.
CASES = [
  # --- axes -----------------------------------------------------------
  {"self::*", "nodes", ["elem:r"], nil, nil, nil},
  {"child::*", "nodes", ["elem:{urn:p}p:item", "elem:item", "elem:item", "elem:meta"], nil, nil, nil},
  {"child::node()", "nodes", ["elem:{urn:p}p:item", "elem:item", "elem:item", "elem:meta", "pi:pi-target:the-data"], nil, nil, nil},
  {"descendant::*", "nodes", ["elem:{urn:p}p:item", "elem:name", "elem:val", "elem:item", "elem:name", "elem:val", "elem:sub", "elem:item", "elem:name", "elem:val", "elem:sub", "elem:sub", "elem:meta"], nil, nil, nil},
  {"descendant-or-self::node()", "nodes", ["elem:r", "elem:{urn:p}p:item", "elem:name", "text:A", "elem:val", "text:10", "comment:c1", "elem:item", "elem:name", "text:B", "elem:val", "text:20", "elem:sub", "elem:item", "elem:name", "text:C", "elem:val", "text:30", "elem:sub", "elem:sub", "elem:meta", "text:raw", "text:tail", "pi:pi-target:the-data"], nil, nil, nil},
  {"descendant-or-self::*", "nodes", ["elem:r", "elem:{urn:p}p:item", "elem:name", "elem:val", "elem:item", "elem:name", "elem:val", "elem:sub", "elem:item", "elem:name", "elem:val", "elem:sub", "elem:sub", "elem:meta"], nil, nil, nil},
  {"parent::*", "nodes", [] of String, nil, nil, nil},
  {"ancestor::*", "nodes", [] of String, nil, nil, nil},
  {"ancestor-or-self::*", "nodes", ["elem:r"], nil, nil, nil},
  {"attribute::*", "nodes", ["@xmlns:p=urn:p", "@xml:lang=en"], nil, nil, nil},
  {"attribute::id", "nodes", [] of String, nil, nil, nil},
  {"@*", "nodes", ["@xmlns:p=urn:p", "@xml:lang=en"], nil, nil, nil},
  {"namespace::*", "nodes", ["ns:urn:p", "ns:http://www.w3.org/XML/1998/namespace"], nil, nil, nil},
  {"namespace::p", "nodes", ["ns:urn:p"], nil, nil, nil},
  {"namespace::xml", "nodes", ["ns:http://www.w3.org/XML/1998/namespace"], nil, nil, nil},
  {"namespace::missing", "nodes", [] of String, nil, nil, nil},
  {"count(namespace::*)", "number", 2.0, nil, nil, nil},
  {"count(namespace::xml)", "number", 1.0, nil, nil, nil},
  {"following::*", "nodes", [] of String, nil, nil, nil},
  {"preceding::*", "nodes", [] of String, nil, nil, nil},
  {"following-sibling::*", "nodes", [] of String, nil, nil, nil},
  {"preceding-sibling::*", "nodes", [] of String, nil, nil, nil},
  {"following-sibling::node()", "nodes", [] of String, nil, nil, nil},

  # --- location paths -------------------------------------------------
  {"item", "nodes", ["elem:item", "elem:item"], nil, nil, nil}, # all fixture elements without a prefix are in no namespace
  {"p:item", "nodes", ["elem:{urn:p}p:item"], nil, nil, nil},
  {"*/*", "nodes", ["elem:name", "elem:val", "elem:name", "elem:val", "elem:sub", "elem:name", "elem:val", "elem:sub", "elem:sub"], nil, nil, nil},
  {"/r/item[2]/sub", "nodes", ["elem:sub", "elem:sub"], nil, nil, nil},
  {"/r/item[2]//sub", "nodes", ["elem:sub", "elem:sub"], nil, nil, nil},
  {"//sub", "nodes", ["elem:sub", "elem:sub", "elem:sub"], nil, nil, nil},
  {"//p:item", "nodes", ["elem:{urn:p}p:item"], nil, nil, nil},
  {".//name", "nodes", ["elem:name", "elem:name", "elem:name"], nil, nil, nil},
  {"/r/meta/text()", "nodes", ["text:raw", "text:tail"], nil, nil, nil},
  {"comment()", "nodes", [] of String, nil, nil, nil}, # c1 is inside p:item, not a child of r
  {"p:item/comment()", "nodes", ["comment:c1"], nil, nil, nil},
  {"processing-instruction()", "nodes", ["pi:pi-target:the-data"], nil, nil, nil},
  {"processing-instruction('pi-target')", "nodes", ["pi:pi-target:the-data"], nil, nil, nil},
  {"processing-instruction('other')", "nodes", [] of String, nil, nil, nil},
  {"/r/item[1]/name/text()", "nodes", ["text:B"], nil, nil, nil},
  {"/p:item", "nodes", [] of String, nil, nil, nil}, # document element is r
  {"/p:r", "nodes", [] of String, nil, nil, nil},

  # --- predicates -----------------------------------------------------
  {"item[1]", "nodes", ["elem:item"], nil, nil, nil},
  {"item[position() = 2]", "nodes", ["elem:item"], nil, nil, nil},
  {"item[last()]", "nodes", ["elem:item"], nil, nil, nil},
  {"item[position() > 1]", "nodes", ["elem:item"], nil, nil, nil},
  {"item[last() - 1]", "nodes", ["elem:item"], nil, nil, nil},
  {"*[@id]", "nodes", ["elem:{urn:p}p:item", "elem:item"], nil, nil, nil},
  {"*[@id='i2']", "nodes", ["elem:item"], nil, nil, nil},
  {"*[name]", "nodes", ["elem:{urn:p}p:item", "elem:item", "elem:item"], nil, nil, nil},
  {"*[val > 15]", "nodes", ["elem:item", "elem:item"], nil, nil, nil},
  {"*[not(sub)]", "nodes", ["elem:{urn:p}p:item", "elem:meta"], nil, nil, nil},
  {"*[@rank][2]", "nodes", ["elem:item"], nil, nil, nil},
  {"*[sub][2]", "nodes", ["elem:item"], nil, nil, nil},
  {"item[@id][@rank='2']", "nodes", ["elem:item"], nil, nil, nil},
  {"*[@id='i1' or @id='i2']", "nodes", ["elem:{urn:p}p:item", "elem:item"], nil, nil, nil},
  {"*[@rank='1' and val='10']", "nodes", ["elem:{urn:p}p:item"], nil, nil, nil},

  # --- unions and order ----------------------------------------------
  {"item | p:item", "nodes", ["elem:{urn:p}p:item", "elem:item", "elem:item"], nil, nil, nil},
  {"//sub | //name | //val", "nodes", ["elem:name", "elem:val", "elem:name", "elem:val", "elem:sub", "elem:name", "elem:val", "elem:sub", "elem:sub"], nil, nil, nil},
  {"//sub | //sub", "nodes", ["elem:sub", "elem:sub", "elem:sub"], nil, nil, nil}, # deduped
  {"//name | //*", "nodes", nil, nil, nil, nil},                                   # checked below as "no duplicates, doc order"

  # --- values and conversions ----------------------------------------
  {"string(/r/item[1]/name)", "string", "B", nil, nil, nil}, # /r/item matches only no-namespace items
  {"string(/r/meta)", "string", "rawtail", nil, nil, nil},   # CDATA participates in string-value
  {"string(/r)", "string", "A10B20C30rawtail", nil, nil, nil},
  {"string(//nonexistent)", "string", "", nil, nil, nil},
  {"string(//@id)", "string", "i1", nil, nil, nil},
  {"string(1.0)", "string", "1", nil, nil, nil},
  {"string(1.5)", "string", "1.5", nil, nil, nil},
  {"string(-0.0)", "string", "0", nil, nil, nil},
  {"number(//item[2]/val)", "number", 30.0, nil, nil, nil},
  {"number(' 42 ')", "number", 42.0, nil, nil, nil},
  {"number('-4.25')", "number", -4.25, nil, nil, nil},
  {"number('abc')", "number", "NaN", nil, nil, nil},
  {"number('')", "number", "NaN", nil, nil, nil},
  {"number('1e2')", "number", "NaN", nil, nil, nil},
  {"number(true())", "number", 1.0, nil, nil, nil},
  {"number(false())", "number", 0.0, nil, nil, nil},
  {"//val > 25", "bool", true, nil, nil, nil}, # existential comparison
  {"//val > 100", "bool", false, nil, nil, nil},
  {"//val != 20", "bool", true, nil, nil, nil},
  {"//sub = 'x'", "bool", false, nil, nil, nil}, # empty string-value vs nonempty
  {"boolean(//item)", "bool", true, nil, nil, nil},
  {"boolean(//zzz)", "bool", false, nil, nil, nil},
  {"boolean(0)", "bool", false, nil, nil, nil},
  {"boolean('0')", "bool", true, nil, nil, nil},
  {"boolean('')", "bool", false, nil, nil, nil},
  {"boolean(NaN)", "bool", false, nil, nil, nil},

  # --- core functions -------------------------------------------------
  {"count(*)", "number", 4.0, nil, nil, nil},
  {"count(//sub)", "number", 3.0, nil, nil, nil},
  {"count(//@*)", "number", 7.0, nil, nil, nil}, # 2 on r, 2+2+1 on items
  {"sum(//val)", "number", 60.0, nil, nil, nil},
  {"sum(//nonexistent)", "number", 0.0, nil, nil, nil},
  {"sum(/r/item/val[position() > 1])", "number", 0.0, nil, nil, nil}, # one val per item: predicate is per context
  {"floor(2.9)", "number", 2.0, nil, nil, nil},
  {"floor(-0.5)", "number", -1.0, nil, nil, nil},
  {"ceiling(2.1)", "number", 3.0, nil, nil, nil},
  {"ceiling(-2.9)", "number", -2.0, nil, nil, nil},
  {"round(3.5)", "number", 4.0, nil, nil, nil},
  {"round(-3.5)", "number", -3.0, nil, nil, nil},
  {"round(-2.5)", "number", -2.0, nil, nil, nil},
  {"round('3.7')", "number", 4.0, nil, nil, nil},
  {"concat('a', '-', 'b', '-', 'c')", "string", "a-b-c", nil, nil, nil},
  {"starts-with(/r/@xml:lang, 'en')", "bool", true, nil, nil, nil},
  {"contains(/r/@xml:lang, 'n')", "bool", true, nil, nil, nil},
  {"substring-before('/r/@x', '/')", "string", "", nil, nil, nil},
  {"substring-before('a/b/c', '/')", "string", "a", nil, nil, nil},
  {"substring-after('a/b/c', '/')", "string", "b/c", nil, nil, nil},
  {"substring('12345', 2)", "string", "2345", nil, nil, nil},
  {"substring('12345', -2, 7)", "string", "1234", nil, nil, nil},
  {"substring('12345', 3, 100)", "string", "345", nil, nil, nil},
  {"string-length(/r/item[2]/name)", "number", 1.0, nil, nil, nil},
  {"string-length('')", "number", 0.0, nil, nil, nil},
  {"normalize-space('  a \t b\n\r c ')", "string", "a b c", nil, nil, nil},
  {"normalize-space(//nonexistent)", "string", "", nil, nil, nil},
  {"normalize-space()", "string", "A10B20C30rawtail", nil, nil, nil}, # no arg: string-value of the context node
  {"translate('aAbc', 'aA', 'xX')", "string", "xXbc", nil, nil, nil},
  {"translate('hello', 'elo', 'ELO')", "string", "hELLO", nil, nil, nil},
  {"translate('hello', 'e', '')", "string", "hllo", nil, nil, nil},
  {"name(/r)", "string", "r", nil, nil, nil},
  {"local-name(/r)", "string", "r", nil, nil, nil},
  {"name(/r/item[1])", "string", "item", nil, nil, nil}, # /r/item matches only no-namespace items
  {"local-name(/r/item[1])", "string", "item", nil, nil, nil},
  {"namespace-uri(/r/p:item)", "string", "urn:p", nil, nil, nil},
  {"namespace-uri(/r/item[1])", "string", "", nil, nil, nil},
  {"namespace-uri(/r/item[2])", "string", "", nil, nil, nil},
  {"name(/r/@xml:lang)", "string", "xml:lang", nil, nil, nil},
  {"local-name(/r/@xml:lang)", "string", "lang", nil, nil, nil},
  {"namespace-uri(/r/item[1]/@id)", "string", "", nil, nil, nil}, # unprefixed attrs have no ns
  {"name(comment())", "string", "", nil, nil, nil},
  {"name(processing-instruction())", "string", "pi-target", nil, nil, nil},
  {"local-name(processing-instruction())", "string", "pi-target", nil, nil, nil},
  {"string(//comment())", "string", "c1", nil, nil, nil},
  {"string(processing-instruction())", "string", "the-data", nil, nil, nil},

  # --- variables ------------------------------------------------------
  {"$n", "number", 3.0, nil, nil, {"n" => 3.0}},
  {"$s = 'hi'", "bool", true, nil, nil, {"s" => "hi"}},
  {"item[$i]", "nodes", ["elem:item"], nil, nil, {"i" => 2.0}},
  {"count(item) = $n", "bool", true, nil, nil, {"n" => 2.0}},
  {"$missing", "error", "undefined variable", nil, nil, nil},
  {"$n +", "error", nil, nil, nil, {"n" => 1.0}},

  # --- id() -----------------------------------------------------------
  {"id('i1')", "nodes", ["elem:{urn:p}p:item"], nil, nil, nil},
  {"id('i2')/name", "nodes", ["elem:name"], nil, nil, nil},
  {"id('i1 i2')", "nodes", ["elem:{urn:p}p:item", "elem:item"], nil, nil, nil},
  {"id('i1 i1 i2')", "nodes", ["elem:{urn:p}p:item", "elem:item"], nil, nil, nil}, # deduped
  {"id('missing')", "nodes", [] of String, nil, nil, nil},
  {"id(/r/item[1]/@rank)", "nodes", [] of String, nil, nil, nil}, # rank is not an ID attribute
  {"id('i2')/ancestor-or-self::*", "nodes", ["elem:r", "elem:item"], nil, nil, nil},

  # --- namespace maps -------------------------------------------------
  {"x:item", "nodes", ["elem:{urn:p}p:item"], nil, {"x" => "urn:p"}, nil},
  {"x:*", "nodes", ["elem:{urn:p}p:item"], nil, {"x" => "urn:p"}, nil},
  {"/q:r", "nodes", ["elem:r"], nil, {"q" => ""}, nil},

  # --- arithmetic and operators ---------------------------------------
  {"1 + 2 * 3 - 4 div 2", "number", 5.0, nil, nil, nil},
  {"5 mod 3", "number", 2.0, nil, nil, nil},
  {"-5 mod 3", "number", -2.0, nil, nil, nil},
  {"5 mod -3", "number", 2.0, nil, nil, nil},
  {"1 div 0", "number", "Infinity", nil, nil, nil},
  {"-1 div 0", "number", "-Infinity", nil, nil, nil},
  {"0 div 0", "number", "NaN", nil, nil, nil},
  {"0 div 0 = 0 div 0", "bool", false, nil, nil, nil},
  {"1 div 0 = 1 div 0", "bool", true, nil, nil, nil},
  {"(1 < 2) = true()", "bool", true, nil, nil, nil},
  {"2 = '2'", "bool", true, nil, nil, nil},
  {"true() and 1", "bool", true, nil, nil, nil},
  {"false() or 0", "bool", false, nil, nil, nil},
  {"false() or 'x'", "bool", true, nil, nil, nil},
  {"1 = 1 and 2 = 2", "bool", true, nil, nil, nil},

  # --- syntax errors --------------------------------------------------
  {"item[", "error", nil, nil, nil, nil},
  {"item]]", "error", nil, nil, nil, nil},
  {"//", "error", nil, nil, nil, nil},
  {"item/@", "error", nil, nil, nil, nil},
  {"item::foo", "error", nil, nil, nil, nil},
  {"1 +", "error", nil, nil, nil, nil},
  {"*name", "error", nil, nil, nil, nil},
  {"count()", "error", nil, nil, nil, nil},
  {"item[$n]", "error", nil, nil, nil, nil},
]

DOC  = KXML.parse(CORPUS_FIXTURE)
ROOT = DOC.root || raise "fixture has no root element"

module SpecHelpers
  def corpus_vars(row) : Hash(String, KXML::XPath::Value)?
    row[5].try(&.transform_values { |v| v.as(KXML::XPath::Value) })
  end

  def eval_case(row)
    expr = row[0]
    kind = row[1]
    expected = row[2]
    ctx = row[3].try { |ctx_e| resolve(ctx_e, ROOT) } || ROOT
    case kind
    when "nodes"
      nodes = KXML::XPath.evaluate_nodes(expr, ctx, 1, 1, row[4], corpus_vars(row))
      assert_equal nodes.uniq.size, nodes.size # no duplicates, doc order
      actual = nodes.map { |nd_| describe_node(nd_) }
      if e = row[2].as(Array(String)?)
        assert_equal e, actual
      end
    when "string"
      assert_equal expected, KXML::XPath.evaluate(expr, ctx, 1, 1, row[4], corpus_vars(row))
    when "number"
      v = KXML::XPath.evaluate(expr, ctx, 1, 1, row[4], corpus_vars(row))
      if expected == "NaN"
        assert v.as(Float64).nan?
      elsif expected == "Infinity"
        assert_equal 1, v.as(Float64).infinite?
      elsif expected == "-Infinity"
        assert_equal -1, v.as(Float64).infinite?
      else
        assert_equal expected, v
      end
    when "bool"
      assert_equal expected, KXML::XPath.evaluate(expr, ctx, 1, 1, row[4], corpus_vars(row))
    when "error"
      assert_raises(KXML::XPath::Error) do
        KXML::XPath.evaluate(expr, ctx, 1, 1, row[4], corpus_vars(row))
      end
    else
      raise "unknown kind #{kind}"
    end
  end
end

describe "XPath corpus" do
  {% for row, i in CASES %}
    # The row index keeps generated method names unique: several rows
    # sanitize to the same test name (e.g. repeated "error: item["-style
    # expressions) and minitest methods would otherwise silently collide.
    {% cname = row[1] + ": " + row[0].gsub(/[\n\r\t"]/, " ") + " #" + i.stringify %}
    it {{ cname }} do
      eval_case(CASES[{{ i }}])
    end
  {% end %}
end
