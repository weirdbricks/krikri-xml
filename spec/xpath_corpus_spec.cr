require "./spec_helper"

# Data-driven XPath 1.0 corpus: every case is a row in a table, evaluated
# against one shared fixture. Node-set expectations are described as exact
# node strings ("elem: <name> in <uri>", "@attr=value", "text: ...", ...),
# so adding coverage is adding rows, not code.

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
class Row
  getter expr : String
  getter kind : String
  getter expected : Array(String)? | Bool | Float64 | String
  getter ctx_expr : String?
  getter ns_map : Hash(String, String)?
  getter vars : Hash(String, KXML::XPath::Value)?

  def initialize(@expr, @kind, @expected, @ctx_expr = nil, @ns_map = nil, @vars = nil)
  end
end

def c(expr, kind, expected, ctx_expr = nil, ns_map = nil, vars = nil) : Row
  v = vars.try(&.transform_values(&.as(KXML::XPath::Value)))
  Row.new(expr, kind, expected, ctx_expr, ns_map, v)
end

CASES = [
  # --- axes -----------------------------------------------------------
  c("self::*", "nodes", ["elem:r"]),
  c("child::*", "nodes", ["elem:{urn:p}p:item", "elem:item", "elem:item", "elem:meta"]),
  c("child::node()", "nodes", ["elem:{urn:p}p:item", "elem:item", "elem:item", "elem:meta", "pi:pi-target:the-data"]),
  c("descendant::*", "nodes", ["elem:{urn:p}p:item", "elem:name", "elem:val", "elem:item", "elem:name", "elem:val", "elem:sub", "elem:item", "elem:name", "elem:val", "elem:sub", "elem:sub", "elem:meta"]),
  c("descendant-or-self::node()", "nodes", ["elem:r", "elem:{urn:p}p:item", "elem:name", "text:A", "elem:val", "text:10", "comment:c1", "elem:item", "elem:name", "text:B", "elem:val", "text:20", "elem:sub", "elem:item", "elem:name", "text:C", "elem:val", "text:30", "elem:sub", "elem:sub", "elem:meta", "text:raw", "text:tail", "pi:pi-target:the-data"]),
  c("descendant-or-self::*", "nodes", ["elem:r", "elem:{urn:p}p:item", "elem:name", "elem:val", "elem:item", "elem:name", "elem:val", "elem:sub", "elem:item", "elem:name", "elem:val", "elem:sub", "elem:sub", "elem:meta"]),
  c("parent::*", "nodes", [] of String),
  c("ancestor::*", "nodes", [] of String),
  c("ancestor-or-self::*", "nodes", ["elem:r"]),
  c("attribute::*", "nodes", ["@xmlns:p=urn:p", "@xml:lang=en"]),
  c("attribute::id", "nodes", [] of String),
  c("@*", "nodes", ["@xmlns:p=urn:p", "@xml:lang=en"]),
  c("namespace::*", "nodes", ["ns:urn:p", "ns:http://www.w3.org/XML/1998/namespace"]),
  c("namespace::p", "nodes", ["ns:urn:p"]),
  c("namespace::xml", "nodes", ["ns:http://www.w3.org/XML/1998/namespace"]),
  c("namespace::missing", "nodes", [] of String),
  c("count(namespace::*)", "number", 2.0),
  c("count(namespace::xml)", "number", 1.0),
  c("following::*", "nodes", [] of String),
  c("preceding::*", "nodes", [] of String),
  c("following-sibling::*", "nodes", [] of String),
  c("preceding-sibling::*", "nodes", [] of String),
  c("following-sibling::node()", "nodes", [] of String),

  # --- location paths -------------------------------------------------
  c("item", "nodes", ["elem:item", "elem:item"]), # all fixture elements without a prefix are in no namespace
  c("p:item", "nodes", ["elem:{urn:p}p:item"]),
  c("*/*", "nodes", ["elem:name", "elem:val", "elem:name", "elem:val", "elem:sub", "elem:name", "elem:val", "elem:sub", "elem:sub"]),
  c("/r/item[2]/sub", "nodes", ["elem:sub", "elem:sub"]),
  c("/r/item[2]//sub", "nodes", ["elem:sub", "elem:sub"]),
  c("//sub", "nodes", ["elem:sub", "elem:sub", "elem:sub"]),
  c("//p:item", "nodes", ["elem:{urn:p}p:item"]),
  c(".//name", "nodes", ["elem:name", "elem:name", "elem:name"]),
  c("/r/meta/text()", "nodes", ["text:raw", "text:tail"]),
  c("comment()", "nodes", [] of String), # c1 is inside p:item, not a child of r
  c("p:item/comment()", "nodes", ["comment:c1"]),
  c("processing-instruction()", "nodes", ["pi:pi-target:the-data"]),
  c("processing-instruction('pi-target')", "nodes", ["pi:pi-target:the-data"]),
  c("processing-instruction('other')", "nodes", [] of String),
  c("/r/item[1]/name/text()", "nodes", ["text:B"]),
  c("/p:item", "nodes", [] of String), # document element is r
  c("/p:r", "nodes", [] of String),

  # --- predicates -----------------------------------------------------
  c("item[1]", "nodes", ["elem:item"]),
  c("item[position() = 2]", "nodes", ["elem:item"]),
  c("item[last()]", "nodes", ["elem:item"]),
  c("item[position() > 1]", "nodes", ["elem:item"]),
  c("item[last() - 1]", "nodes", ["elem:item"]),
  c("*[@id]", "nodes", ["elem:{urn:p}p:item", "elem:item"]),
  c("*[@id='i2']", "nodes", ["elem:item"]),
  c("*[name]", "nodes", ["elem:{urn:p}p:item", "elem:item", "elem:item"]),
  c("*[val > 15]", "nodes", ["elem:item", "elem:item"]),
  c("*[not(sub)]", "nodes", ["elem:{urn:p}p:item", "elem:meta"]),
  c("*[@rank][2]", "nodes", ["elem:item"]),
  c("*[sub][2]", "nodes", ["elem:item"]),
  c("item[@id][@rank='2']", "nodes", ["elem:item"]),
  c("*[@id='i1' or @id='i2']", "nodes", ["elem:{urn:p}p:item", "elem:item"]),
  c("*[@rank='1' and val='10']", "nodes", ["elem:{urn:p}p:item"]),

  # --- unions and order ----------------------------------------------
  c("item | p:item", "nodes", ["elem:{urn:p}p:item", "elem:item", "elem:item"]),
  c("//sub | //name | //val", "nodes", ["elem:name", "elem:val", "elem:name", "elem:val", "elem:sub", "elem:name", "elem:val", "elem:sub", "elem:sub"]),
  c("//sub | //sub", "nodes", ["elem:sub", "elem:sub", "elem:sub"]), # deduped
  c("//name | //*", "nodes", nil),                                   # checked below as "no duplicates, doc order"

  # --- values and conversions ----------------------------------------
  c("string(/r/item[1]/name)", "string", "B"), # /r/item matches only no-namespace items
  c("string(/r/meta)", "string", "rawtail"),   # CDATA participates in string-value
  c("string(/r)", "string", "A10B20C30rawtail"),
  c("string(//nonexistent)", "string", ""),
  c("string(//@id)", "string", "i1"),
  c("string(1.0)", "string", "1"),
  c("string(1.5)", "string", "1.5"),
  c("string(-0.0)", "string", "0"),
  c("number(//item[2]/val)", "number", 30.0),
  c("number(' 42 ')", "number", 42.0),
  c("number('-4.25')", "number", -4.25),
  c("number('abc')", "number", "NaN"),
  c("number('')", "number", "NaN"),
  c("number('1e2')", "number", "NaN"),
  c("number(true())", "number", 1.0),
  c("number(false())", "number", 0.0),
  c("//val > 25", "bool", true), # existential comparison
  c("//val > 100", "bool", false),
  c("//val != 20", "bool", true),
  c("//sub = 'x'", "bool", false), # empty string-value vs nonempty
  c("boolean(//item)", "bool", true),
  c("boolean(//zzz)", "bool", false),
  c("boolean(0)", "bool", false),
  c("boolean('0')", "bool", true),
  c("boolean('')", "bool", false),
  c("boolean(NaN)", "bool", false),

  # --- core functions -------------------------------------------------
  c("count(*)", "number", 4.0),
  c("count(//sub)", "number", 3.0),
  c("count(//@*)", "number", 7.0), # 2 on r, 2+2+1 on items
  c("sum(//val)", "number", 60.0),
  c("sum(//nonexistent)", "number", 0.0),
  c("sum(/r/item/val[position() > 1])", "number", 0.0), # one val per item: predicate is per context
  c("floor(2.9)", "number", 2.0),
  c("floor(-0.5)", "number", -1.0),
  c("ceiling(2.1)", "number", 3.0),
  c("ceiling(-2.9)", "number", -2.0),
  c("round(3.5)", "number", 4.0),
  c("round(-3.5)", "number", -3.0),
  c("round(-2.5)", "number", -2.0),
  c("round('3.7')", "number", 4.0),
  c("concat('a', '-', 'b', '-', 'c')", "string", "a-b-c"),
  c("starts-with(/r/@xml:lang, 'en')", "bool", true),
  c("contains(/r/@xml:lang, 'n')", "bool", true),
  c("substring-before('/r/@x', '/')", "string", ""),
  c("substring-before('a/b/c', '/')", "string", "a"),
  c("substring-after('a/b/c', '/')", "string", "b/c"),
  c("substring('12345', 2)", "string", "2345"),
  c("substring('12345', -2, 7)", "string", "1234"),
  c("substring('12345', 3, 100)", "string", "345"),
  c("string-length(/r/item[2]/name)", "number", 1.0),
  c("string-length('')", "number", 0.0),
  c("normalize-space('  a \t b\n\r c ')", "string", "a b c"),
  c("normalize-space(//nonexistent)", "string", ""),
  c("normalize-space()", "string", "A10B20C30rawtail"), # no arg: string-value of the context node
  c("translate('aAbc', 'aA', 'xX')", "string", "xXbc"),
  c("translate('hello', 'elo', 'ELO')", "string", "hELLO"),
  c("translate('hello', 'e', '')", "string", "hllo"),
  c("name(/r)", "string", "r"),
  c("local-name(/r)", "string", "r"),
  c("name(/r/item[1])", "string", "item"), # /r/item matches only no-namespace items
  c("local-name(/r/item[1])", "string", "item"),
  c("namespace-uri(/r/p:item)", "string", "urn:p"),
  c("namespace-uri(/r/item[1])", "string", ""),
  c("namespace-uri(/r/item[2])", "string", ""),
  c("name(/r/@xml:lang)", "string", "xml:lang"),
  c("local-name(/r/@xml:lang)", "string", "lang"),
  c("namespace-uri(/r/item[1]/@id)", "string", ""), # unprefixed attrs have no ns
  c("name(comment())", "string", ""),
  c("name(processing-instruction())", "string", "pi-target"),
  c("local-name(processing-instruction())", "string", "pi-target"),
  c("string(//comment())", "string", "c1"),
  c("string(processing-instruction())", "string", "the-data"),

  # --- variables ------------------------------------------------------
  c("$n", "number", 3.0, nil, nil, {"n" => 3.0}),
  c("$s = 'hi'", "bool", true, nil, nil, {"s" => "hi"}),
  c("item[$i]", "nodes", ["elem:item"], nil, nil, {"i" => 2.0}),
  c("count(item) = $n", "bool", true, nil, nil, {"n" => 2.0}),
  c("$missing", "error", "undefined variable"),
  c("$n +", "error", nil, nil, nil, {"n" => 1.0}),

  # --- id() -----------------------------------------------------------
  c("id('i1')", "nodes", ["elem:{urn:p}p:item"]),
  c("id('i2')/name", "nodes", ["elem:name"]),
  c("id('i1 i2')", "nodes", ["elem:{urn:p}p:item", "elem:item"]),
  c("id('i1 i1 i2')", "nodes", ["elem:{urn:p}p:item", "elem:item"]), # deduped
  c("id('missing')", "nodes", [] of String),
  c("id(/r/item[1]/@rank)", "nodes", [] of String), # rank is not an ID attribute
  c("id('i2')/ancestor-or-self::*", "nodes", ["elem:r", "elem:item"]),

  # --- namespace maps -------------------------------------------------
  c("x:item", "nodes", ["elem:{urn:p}p:item"], nil, {"x" => "urn:p"}),
  c("x:*", "nodes", ["elem:{urn:p}p:item"], nil, {"x" => "urn:p"}),
  c("/q:r", "nodes", ["elem:r"], nil, {"q" => ""}),

  # --- arithmetic and operators ---------------------------------------
  c("1 + 2 * 3 - 4 div 2", "number", 5.0),
  c("5 mod 3", "number", 2.0),
  c("-5 mod 3", "number", -2.0),
  c("5 mod -3", "number", 2.0),
  c("1 div 0", "number", "Infinity"),
  c("-1 div 0", "number", "-Infinity"),
  c("0 div 0", "number", "NaN"),
  c("0 div 0 = 0 div 0", "bool", false),
  c("1 div 0 = 1 div 0", "bool", true),
  c("(1 < 2) = true()", "bool", true),
  c("2 = '2'", "bool", true),
  c("true() and 1", "bool", true),
  c("false() or 0", "bool", false),
  c("false() or 'x'", "bool", true),
  c("1 = 1 and 2 = 2", "bool", true),

  # --- syntax errors --------------------------------------------------
  c("item[", "error", nil),
  c("item]]", "error", nil),
  c("//", "error", nil),
  c("item/@", "error", nil),
  c("item::foo", "error", nil),
  c("1 +", "error", nil),
  c("*name", "error", nil),
  c("count()", "error", nil),
  c("item[$n]", "error", nil),
]

DOC  = KXML.parse(CORPUS_FIXTURE)
ROOT = DOC.root || raise "fixture has no root element"

def eval_case(row)
  expr, kind, expected = row.expr, row.kind, row.expected
  ctx = row.ctx_expr.try { |ctx_e| resolve(ctx_e, ROOT) } || ROOT
  case kind
  when "nodes"
    nodes = KXML::XPath.evaluate_nodes(expr, ctx, 1, 1, row.ns_map, row.vars)
    nodes.size.should eq(nodes.uniq.size) # no duplicates, doc order
    actual = nodes.map { |nd_| describe_node(nd_) }
    if e = row.expected.as(Array(String)?)
      actual.should eq(e)
    end
  when "string"
    KXML::XPath.evaluate(expr, ctx, 1, 1, row.ns_map, row.vars).should eq(expected)
  when "number"
    v = KXML::XPath.evaluate(expr, ctx, 1, 1, row.ns_map, row.vars)
    if expected == "NaN"
      v.as(Float64).nan?.should be_true
    elsif expected == "Infinity"
      v.as(Float64).infinite?.should eq(1)
    elsif expected == "-Infinity"
      v.as(Float64).infinite?.should eq(-1)
    else
      v.should eq(expected)
    end
  when "bool"
    KXML::XPath.evaluate(expr, ctx, 1, 1, row.ns_map, row.vars).should eq(expected)
  when "error"
    expect_raises(KXML::XPath::Error) do
      KXML::XPath.evaluate(expr, ctx, 1, 1, row.ns_map, row.vars)
    end
  else
    raise "unknown kind #{kind}"
  end
end

describe "XPath corpus" do
  CASES.each do |row|
    it "#{row.kind}: #{row.expr}" do
      eval_case(row)
    end
  end
end
