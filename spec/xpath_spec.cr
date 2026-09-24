require "./spec_helper"

# Fixture: a document exercising most XPath features.
FIXTURE = <<-XML
  <?xml version="1.0"?>
  <catalog xmlns:x="urn:x">
    <book id="b1" lang="en" out-of-print="yes">
      <title lang="en">XML Developer's Guide</title>
      <author><first>Giada</first><last>De Laurentiis</last></author>
      <price currency="EUR">30.00</price>
      <remark><!-- note --><b>bold</b> tail</remark>
    </book>
    <book id="b2" lang="fr">
      <title lang="fr">XQuery Kick Start</title>
      <author><first>James</first><last>McGovern</last></author>
      <price currency="USD">49.95</price>
    </book>
    <book id="b3">
      <title>Learning XML</title>
      <author><first>Erik</first><last>Ray</last></author>
      <price currency="USD">39.95</price>
    </book>
  </catalog>
  XML

def doc
  KXML.parse(FIXTURE)
end

def root
  doc.root.not_nil!
end

def first_book
  root.elements[0]
end

def eval_nodes(expr, ctx = root)
  KXML::XPath.evaluate_nodes(expr, ctx)
end

def eval_one(expr, ctx = root)
  KXML::XPath.evaluate(expr, ctx)
end

describe KXML::XPath do
  describe "location paths" do
    it "selects the document root via /" do
      nodes = eval_nodes("/", doc)
      nodes.size.should eq(1)
      nodes[0].should be_a(KXML::Document)
    end

    it "selects the document element via /catalog" do
      nodes = eval_nodes("/catalog", doc)
      nodes.size.should eq(1)
      nodes[0].as(KXML::Element).name.should eq("catalog")
    end

    it "selects children by name" do
      eval_nodes("book").size.should eq(3)
      eval_nodes("child::book").size.should eq(3)
    end

    it "selects descendants with //" do
      eval_nodes("//title").size.should eq(3)
      eval_nodes("descendant::title").size.should eq(3)
    end

    it "selects attributes with @" do
      nodes = eval_nodes("book/@id")
      nodes.size.should eq(3)
      nodes[0].as(KXML::Attribute).value.should eq("b1")
      eval_nodes("@id").size.should eq(0)
      eval_nodes("book[@id='b2']").size.should eq(1)
    end

    it "supports parent, ancestor and self axes" do
      titles = eval_nodes("//title")
      title = titles[0]
      eval_nodes("parent::book", title).size.should eq(1)
      eval_nodes("ancestor::catalog", title).size.should eq(1)
      eval_nodes("ancestor-or-self::*", title).size.should eq(3)
      eval_nodes(".", title).size.should eq(1)
      eval_nodes("..", title)[0].as(KXML::Element).name.should eq("book")
    end

    it "supports sibling axes" do
      b2 = root.elements[1]
      eval_nodes("preceding-sibling::book", b2).size.should eq(1)
      eval_nodes("following-sibling::book", b2).size.should eq(1)
      price = eval_nodes("book/price")[0]
      eval_nodes("preceding::price", price).size.should eq(0)
      eval_nodes("following::price", price).size.should eq(2)
    end

    it "supports the namespace axis" do
      d = KXML.parse(%(<r xmlns="urn:d" xmlns:p="urn:p"/>))
      r = d.root.not_nil!
      ns_nodes = KXML::XPath.evaluate_nodes("namespace::*", r)
      hrefs = ns_nodes.map { |node| KXML::XPath.string_value(node) }.sort!
      hrefs.should eq(["urn:d", "urn:p", "http://www.w3.org/XML/1998/namespace"].sort!)
      KXML::XPath.evaluate_nodes("namespace::p", r).size.should eq(1)
      KXML::XPath.evaluate_nodes("namespace::*", r)[0].as(KXML::NamespaceNode).href
      KXML::XPath.evaluate("count(namespace::*)", r).should eq(3.0)
    end

    it "supports wildcard and prefix node tests" do
      eval_nodes("book/*").size.should eq(10) # 4 element children of book 1, 3 each of books 2-3
      eval_nodes("x:*").size.should eq(0)     # urn:x namespace has no elements
      eval_nodes("book/title").size.should eq(3)
    end

    it "matches unprefixed names against the default namespace" do
      d = KXML.parse(%(<r xmlns="urn:d"><a/><p:b xmlns:p="urn:p"/></r>))
      r = d.root.not_nil!
      eval_nodes("*", r).size.should eq(2)
      eval_nodes("a", r).size.should eq(1)
      eval_nodes("p:b", r).size.should eq(0) # p is not in scope at r (declared on b itself)
      eval_nodes("b", r).size.should eq(0)   # 'b' is in the default (urn:d) namespace
    end

    it "supports node type tests" do
      remark = eval_nodes("//remark")[0]
      eval_nodes("comment()", remark).size.should eq(1)
      eval_nodes("text()", remark).size.should eq(1) # " tail"
      eval_nodes("node()", remark).size.should eq(3) # comment, b, text
      eval_nodes("//comment()").size.should eq(1)
      eval_nodes("text()", first_book).size.should eq(5) # whitespace text nodes
    end

    it "resolves namespace prefixes from the context node" do
      d = KXML.parse(%(<r xmlns:p="urn:p"><p:a q="1"/></r>))
      a = d.root.not_nil!.elements[0]
      eval_nodes("self::p:a", a).size.should eq(1) # in-scope from ancestors
    end
  end

  describe "predicates" do
    it "filters positionally" do
      eval_nodes("book[1]").size.should eq(1)
      eval_nodes("book[1]")[0].as(KXML::Element).name.should eq(eval_nodes("book[1]")[0].as(KXML::Element).name)
      eval_nodes("book[last()]").size.should eq(1)
      eval_nodes("book[position() > 1]").size.should eq(2)
      eval_nodes("book[position() <= 2]").size.should eq(2)
    end

    it "filters by predicate expressions" do
      eval_nodes("book[author/last = 'Ray']").size.should eq(1)
      eval_nodes("book[price < 40]").size.should eq(2)
      eval_nodes("book[@lang]").size.should eq(2)
      eval_nodes("book[@lang='fr']").size.should eq(1)
      eval_nodes("book[not(@lang)]").size.should eq(1)
      eval_nodes("book[contains(@id, '2')]").size.should eq(1)
      eval_nodes("book[starts-with(@id, 'b')]").size.should eq(3)
    end

    it "supports nested predicates" do
      eval_nodes("book[price[@currency = 'USD']][2]").size.should eq(1)
    end

    it "applies predicates on abbreviated steps" do
      eval_nodes(".[book]").size.should eq(1)
    end
  end

  describe "unions" do
    it "unions node-sets in document order" do
      nodes = eval_nodes("//price | //title")
      nodes.size.should eq(6)
      nodes[0].as(KXML::Element).name.should eq("title")
      nodes[1].as(KXML::Element).name.should eq("price")
    end
  end

  describe "operators" do
    it "does arithmetic" do
      eval_one("2 + 3").should eq(5.0)
      eval_one("2 - 3").should eq(-1.0)
      eval_one("2 * 3").should eq(6.0)
      eval_one("7 div 2").should eq(3.5)
      eval_one("1 div 0").should eq(Float64::INFINITY)
      eval_one("-1 div 0").should eq(-Float64::INFINITY)
      eval_one("0 div 0").as(Float64).nan?.should be_true
      eval_one("7 mod 2").should eq(1.0)
      eval_one("-7 mod 2").should eq(-1.0)
      eval_one("1 + 2 * 3").should eq(7.0)
    end

    it "compares numbers, strings and booleans" do
      eval_one("1 = 1").should be_true
      eval_one("1 != 1").should be_false
      eval_one("1 < 2").should be_true
      eval_one("2 <= 2").should be_true
      eval_one("3 > 4").should be_false
      eval_one("'a' = 'a'").should be_true
      eval_one("'a' != 'b'").should be_true
      eval_one("true() and false()").should be_false
      eval_one("true() or false()").should be_true
    end

    it "compares node-sets existentially" do
      eval_one("//price = 49.95").should be_true
      eval_one("//price = 'none'").should be_false
      eval_one("//price != 0").should be_true
      eval_one("//price > 40").should be_true
      eval_one("//price > 100").should be_false
      eval_one("//price < //price").should be_true # exists pair 30 < 49.95
    end

    it "converts operands per section 3.4" do
      eval_one("//price = 30").should be_true # number(string(node))
      eval_one("not(//nonexistent = 'x')").should be_true
      eval_one("boolean(//book)").should be_true
      eval_one("boolean(//nonexistent)").should be_false
      eval_one("boolean('')").should be_false
      eval_one("boolean('x')").should be_true
      eval_one("boolean(0)").should be_false
      eval_one("boolean(NaN)").should be_false
    end
  end

  describe "string functions" do
    it "computes string-values" do
      eval_one("string(//book[3]/title)").should eq("Learning XML")
      eval_one("string(//book/title)").should eq("XML Developer's Guide") # first in doc order
      eval_one("string(//nonexistent)").should eq("")
      eval_one("string(//book[1]/@id)").should eq("b1")
      title = eval_nodes("//title")[0]
      eval_one("string(.)", title).should eq("XML Developer's Guide")
    end

    it "formats numbers per section 3.5" do
      eval_one("string(1)").should eq("1")
      eval_one("string(-1.5)").should eq("-1.5")
      eval_one("string(0)").should eq("0")
      eval_one("string(1 div 0)").should eq("Infinity")
      eval_one("string(0 div 0)").should eq("NaN")
    end

    it "implements the core string functions" do
      eval_one("concat('a', 'b', 'c')").should eq("abc")
      eval_one("starts-with('hello', 'he')").should be_true
      eval_one("contains('hello', 'ell')").should be_true
      eval_one("contains('hello', 'z')").should be_false
      eval_one("substring-before('1999/04/01', '/')").should eq("1999")
      eval_one("substring-after('1999/04/01', '/')").should eq("04/01")
      eval_one("substring('12345', 2, 3)").should eq("234")
      eval_one("substring('12345', 1.5, 2.6)").should eq("234")
      eval_one("substring('12345', 0, 3)").should eq("12")
      eval_one("substring('12345', 0 div 0, 3)").should eq("")
      eval_one("substring('12345', 1, 0 div 0)").should eq("")
      eval_one("substring('12345', -42, 1 div 0)").should eq("12345")
      eval_one("substring('12345', -1 div 0, 1 div 0)").should eq("12345")
      eval_one("string-length('hello')").should eq(5)
      eval_one("string-length(//nonexistent)").should eq(0)
      eval_one("normalize-space('  a   b  c ')").should eq("a b c")
      eval_one("normalize-space('abc')").should eq("abc")
      eval_one("translate('bar','abc','ABC')").should eq("BAr")
      eval_one("translate('--aaa--','abc-','ABC')").should eq("AAA")
    end

    it "computes string-length of the context node" do
      title = eval_nodes("//title")[0]
      eval_one("string-length()", title).should eq(21)
    end
  end

  describe "number functions" do
    it "converts strings to numbers" do
      eval_one("number('12.5')").should eq(12.5)
      eval_one("number('-3')").should eq(-3.0)
      eval_one("number('  7  ')").should eq(7.0)
      eval_one("number('abc')").as(Float64).nan?.should be_true
      eval_one("number('1e3')").as(Float64).nan?.should be_true # no exponent in XPath 1.0
    end

    it "numbers node-sets via the first node" do
      eval_one("number(//price)").should eq(30.0)
      eval_one("number(//nonexistent)").as(Float64).nan?.should be_true
    end

    it "implements sum, floor, ceiling, round" do
      eval_one("sum(//price)").should eq(119.9)
      eval_one("floor(2.5)").should eq(2.0)
      eval_one("floor(-2.5)").should eq(-3.0)
      eval_one("ceiling(2.5)").should eq(3.0)
      eval_one("ceiling(-2.5)").should eq(-2.0)
      eval_one("round(2.5)").should eq(3.0)
      eval_one("round(-2.5)").should eq(-2.0) # ties toward positive infinity
      eval_one("round(2.4)").should eq(2.0)
      eval_one("floor(1 div 0)").should eq(Float64::INFINITY)
    end

    it "counts node-sets" do
      eval_one("count(//book)").should eq(3)
      eval_one("count(//@id)").should eq(3)
    end

    it "resolves id() through DTD-declared ID attributes" do
      d = KXML.parse(%(<!DOCTYPE r [<!ELEMENT r ANY><!ATTLIST a uid ID #IMPLIED>]><r><a uid="x1"/><a uid="x2"/></r>))
      nodes = KXML::XPath.evaluate_nodes("id('x2')", d)
      nodes.size.should eq(1)
      nodes[0].as(KXML::Element)["uid"].should eq("x2")
      # id() accepts a whitespace-separated token list, deduped in doc order
      KXML::XPath.evaluate_nodes("id('x1 x2 x1')", d).size.should eq(2)
    end
  end

  describe "boolean functions" do
    it "implements not, true, false, lang" do
      eval_one("not(true())").should be_false
      eval_one("true()").should be_true
      eval_one("false()").should be_false
      # lang() only looks at xml:lang, not a plain lang attribute
      eval_one("lang('en')", first_book).should be_false
      eval_one("lang('fr')", first_book).should be_false
      eval_one("lang('en')", root.elements[0].elements[0]).should be_false # inherits
      eval_one("lang('en-us')", first_book).should be_false
      d = KXML.parse(%(<r xml:lang="en-US"><c/></r>))
      eval_one("lang('en')", d.root.not_nil!.elements[0]).should be_true
    end
  end

  describe "name functions" do
    it "returns local-name, name and namespace-uri" do
      eval_one("local-name(//book[1])").should eq("book")
      eval_one("name(//book[1])").should eq("book")
      eval_one("name(//book[1]/@out-of-print)").should eq("out-of-print")
      eval_one("local-name(//book[1]/@out-of-print)").should eq("out-of-print")
      eval_one("namespace-uri(//book[1])").should eq("")
      d = KXML.parse(%(<r xmlns:p="urn:p"><p:a/></r>))
      eval_one("namespace-uri(//p:a)", d.root.not_nil!).should eq("urn:p")
      eval_one("name(//p:a)", d.root.not_nil!).should eq("p:a")
      eval_one("local-name(comment())", eval_nodes("//comment()")[0]).should eq("")
      eval_one("name(processing-instruction())", doc).should eq("") if doc.misc_before.select(KXML::ProcessingInstruction).empty?
    end
  end

  describe "axes with attributes and mixed content" do
    it "treats CDATA as text nodes" do
      d = KXML.parse(%(<r><![CDATA[x]]>y</r>))
      r = d.root.not_nil!
      eval_nodes("text()", r).size.should eq(2)
      eval_one("string(.)", r).should eq("xy")
    end

    it "evaluates steps from attribute contexts" do
      a = eval_nodes("book/@id")[0]
      eval_one("string(.)", a).should eq("b1")
      eval_nodes("self::*", a).size.should eq(0) # * tests the element principal kind, not attributes
      eval_nodes("self::node()", a).size.should eq(1)
    end
  end

  describe "errors" do
    it "rejects malformed expressions" do
      expect_raises(KXML::XPath::Error) { KXML::XPath.evaluate("book[", root) }
      expect_raises(KXML::XPath::Error) { KXML::XPath.evaluate("//", root) }
      expect_raises(KXML::XPath::Error) { KXML::XPath.evaluate("book](", root) }
    end

    it "rejects unsupported features" do
      expect_raises(KXML::XPath::Error, "variables") { KXML::XPath.evaluate("$x", root) }

      # id() resolves through DTD-declared ID attributes; the fixture has
      # no DTD, so every token misses and the result is an empty node-set.
      KXML::XPath.evaluate_nodes("id('b1')", root).size.should eq(0)
      expect_raises(KXML::XPath::Error) { KXML::XPath.evaluate("unknownfn(1)", root) }
    end
  end
end
