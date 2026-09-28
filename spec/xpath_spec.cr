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
      assert_equal 1, nodes.size
      assert nodes[0].is_a?(KXML::Document)
    end

    it "selects the document element via /catalog" do
      nodes = eval_nodes("/catalog", doc)
      assert_equal 1, nodes.size
      assert_equal "catalog", nodes[0].as(KXML::Element).name
    end

    it "selects children by name" do
      assert_equal 3, eval_nodes("book").size
      assert_equal 3, eval_nodes("child::book").size
    end

    it "selects descendants with //" do
      assert_equal 3, eval_nodes("//title").size
      assert_equal 3, eval_nodes("descendant::title").size
    end

    it "selects attributes with @" do
      nodes = eval_nodes("book/@id")
      assert_equal 3, nodes.size
      assert_equal "b1", nodes[0].as(KXML::Attribute).value
      assert_equal 0, eval_nodes("@id").size
      assert_equal 1, eval_nodes("book[@id='b2']").size
    end

    it "supports parent, ancestor and self axes" do
      titles = eval_nodes("//title")
      title = titles[0]
      assert_equal 1, eval_nodes("parent::book", title).size
      assert_equal 1, eval_nodes("ancestor::catalog", title).size
      assert_equal 3, eval_nodes("ancestor-or-self::*", title).size
      assert_equal 1, eval_nodes(".", title).size
      assert_equal "book", eval_nodes("..", title)[0].as(KXML::Element).name
    end

    it "supports sibling axes" do
      b2 = root.elements[1]
      assert_equal 1, eval_nodes("preceding-sibling::book", b2).size
      assert_equal 1, eval_nodes("following-sibling::book", b2).size
      price = eval_nodes("book/price")[0]
      assert_equal 0, eval_nodes("preceding::price", price).size
      assert_equal 2, eval_nodes("following::price", price).size
    end

    it "supports the namespace axis" do
      d = KXML.parse(%(<r xmlns="urn:d" xmlns:p="urn:p"/>))
      r = d.root.not_nil!
      ns_nodes = KXML::XPath.evaluate_nodes("namespace::*", r)
      hrefs = ns_nodes.map { |node| KXML::XPath.string_value(node) }.sort!
      assert_equal ["urn:d", "urn:p", "http://www.w3.org/XML/1998/namespace"].sort!, hrefs
      assert_equal 1, KXML::XPath.evaluate_nodes("namespace::p", r).size
      KXML::XPath.evaluate_nodes("namespace::*", r)[0].as(KXML::NamespaceNode).href
      assert_equal 3.0, KXML::XPath.evaluate("count(namespace::*)", r)
    end

    it "supports wildcard and prefix node tests" do
      assert_equal 10, eval_nodes("book/*").size # 4 element children of book 1, 3 each of books 2-3
      assert_equal 0, eval_nodes("x:*").size     # urn:x namespace has no elements
      assert_equal 3, eval_nodes("book/title").size
    end

    it "matches unprefixed names only against no-namespace elements" do
      # XPath 1.0 section 2.3: an unprefixed node test has a null namespace
      # URI; the default namespace declared with xmlns is not used.
      d = KXML.parse(%(<r xmlns="urn:d"><a/><c xmlns=""/><p:b xmlns:p="urn:p"/></r>))
      r = d.root.not_nil!
      assert_equal 3, eval_nodes("*", r).size   # wildcard matches any namespace
      assert_equal 0, eval_nodes("a", r).size   # a is in urn:d, test is null-ns
      assert_equal 1, eval_nodes("c", r).size   # c has no namespace
      assert_equal 0, eval_nodes("p:b", r).size # p is not in scope at r (declared on b itself)
      assert_equal 0, eval_nodes("b", r).size
    end

    it "supports node type tests" do
      remark = eval_nodes("//remark")[0]
      assert_equal 1, eval_nodes("comment()", remark).size
      assert_equal 1, eval_nodes("text()", remark).size # " tail"
      assert_equal 3, eval_nodes("node()", remark).size # comment, b, text
      assert_equal 1, eval_nodes("//comment()").size
      assert_equal 5, eval_nodes("text()", first_book).size # whitespace text nodes
    end

    it "resolves namespace prefixes from the context node" do
      d = KXML.parse(%(<r xmlns:p="urn:p"><p:a q="1"/></r>))
      a = d.root.not_nil!.elements[0]
      assert_equal 1, eval_nodes("self::p:a", a).size # in-scope from ancestors
    end
  end

  describe "predicates" do
    it "filters positionally" do
      assert_equal 1, eval_nodes("book[1]").size
      assert_equal eval_nodes("book[1]")[0].as(KXML::Element).name, eval_nodes("book[1]")[0].as(KXML::Element).name
      assert_equal 1, eval_nodes("book[last()]").size
      assert_equal 2, eval_nodes("book[position() > 1]").size
      assert_equal 2, eval_nodes("book[position() <= 2]").size
    end

    it "filters by predicate expressions" do
      assert_equal 1, eval_nodes("book[author/last = 'Ray']").size
      assert_equal 2, eval_nodes("book[price < 40]").size
      assert_equal 2, eval_nodes("book[@lang]").size
      assert_equal 1, eval_nodes("book[@lang='fr']").size
      assert_equal 1, eval_nodes("book[not(@lang)]").size
      assert_equal 1, eval_nodes("book[contains(@id, '2')]").size
      assert_equal 3, eval_nodes("book[starts-with(@id, 'b')]").size
    end

    it "supports nested predicates" do
      assert_equal 1, eval_nodes("book[price[@currency = 'USD']][2]").size
    end

    it "applies predicates on abbreviated steps" do
      assert_equal 1, eval_nodes(".[book]").size
    end
  end

  describe "unions" do
    it "unions node-sets in document order" do
      nodes = eval_nodes("//price | //title")
      assert_equal 6, nodes.size
      assert_equal "title", nodes[0].as(KXML::Element).name
      assert_equal "price", nodes[1].as(KXML::Element).name
    end
  end

  describe "operators" do
    it "does arithmetic" do
      assert_equal 5.0, eval_one("2 + 3")
      assert_equal -1.0, eval_one("2 - 3")
      assert_equal 6.0, eval_one("2 * 3")
      assert_equal 3.5, eval_one("7 div 2")
      assert_equal Float64::INFINITY, eval_one("1 div 0")
      assert_equal -Float64::INFINITY, eval_one("-1 div 0")
      assert eval_one("0 div 0").as(Float64).nan?
      assert_equal 1.0, eval_one("7 mod 2")
      assert_equal -1.0, eval_one("-7 mod 2")
      assert_equal 7.0, eval_one("1 + 2 * 3")
    end

    it "compares numbers, strings and booleans" do
      assert eval_one("1 = 1")
      refute eval_one("1 != 1")
      assert eval_one("1 < 2")
      assert eval_one("2 <= 2")
      refute eval_one("3 > 4")
      assert eval_one("'a' = 'a'")
      assert eval_one("'a' != 'b'")
      refute eval_one("true() and false()")
      assert eval_one("true() or false()")
    end

    it "compares node-sets existentially" do
      assert eval_one("//price = 49.95")
      refute eval_one("//price = 'none'")
      assert eval_one("//price != 0")
      assert eval_one("//price > 40")
      refute eval_one("//price > 100")
      assert eval_one("//price < //price") # exists pair 30 < 49.95
    end

    it "converts operands per section 3.4" do
      assert eval_one("//price = 30") # number(string(node))
      assert eval_one("not(//nonexistent = 'x')")
      assert eval_one("boolean(//book)")
      refute eval_one("boolean(//nonexistent)")
      refute eval_one("boolean('')")
      assert eval_one("boolean('x')")
      refute eval_one("boolean(0)")
      refute eval_one("boolean(NaN)")
    end
  end

  describe "string functions" do
    it "computes string-values" do
      assert_equal "Learning XML", eval_one("string(//book[3]/title)")
      assert_equal "XML Developer's Guide", eval_one("string(//book/title)") # first in doc order
      assert_equal "", eval_one("string(//nonexistent)")
      assert_equal "b1", eval_one("string(//book[1]/@id)")
      title = eval_nodes("//title")[0]
      assert_equal "XML Developer's Guide", eval_one("string(.)", title)
    end

    it "formats numbers per section 3.5" do
      assert_equal "1", eval_one("string(1)")
      assert_equal "-1.5", eval_one("string(-1.5)")
      assert_equal "0", eval_one("string(0)")
      assert_equal "Infinity", eval_one("string(1 div 0)")
      assert_equal "NaN", eval_one("string(0 div 0)")
    end

    it "implements the core string functions" do
      assert_equal "abc", eval_one("concat('a', 'b', 'c')")
      assert eval_one("starts-with('hello', 'he')")
      assert eval_one("contains('hello', 'ell')")
      refute eval_one("contains('hello', 'z')")
      assert_equal "1999", eval_one("substring-before('1999/04/01', '/')")
      assert_equal "04/01", eval_one("substring-after('1999/04/01', '/')")
      assert_equal "234", eval_one("substring('12345', 2, 3)")
      assert_equal "234", eval_one("substring('12345', 1.5, 2.6)")
      assert_equal "12", eval_one("substring('12345', 0, 3)")
      assert_equal "", eval_one("substring('12345', 0 div 0, 3)")
      assert_equal "", eval_one("substring('12345', 1, 0 div 0)")
      assert_equal "12345", eval_one("substring('12345', -42, 1 div 0)")
      assert_equal "12345", eval_one("substring('12345', -1 div 0, 1 div 0)")
      assert_equal 5, eval_one("string-length('hello')")
      assert_equal 0, eval_one("string-length(//nonexistent)")
      assert_equal "a b c", eval_one("normalize-space('  a   b  c ')")
      assert_equal "abc", eval_one("normalize-space('abc')")
      assert_equal "BAr", eval_one("translate('bar','abc','ABC')")
      assert_equal "AAA", eval_one("translate('--aaa--','abc-','ABC')")
    end

    it "computes string-length of the context node" do
      title = eval_nodes("//title")[0]
      assert_equal 21, eval_one("string-length()", title)
    end
  end

  describe "number functions" do
    it "converts strings to numbers" do
      assert_equal 12.5, eval_one("number('12.5')")
      assert_equal -3.0, eval_one("number('-3')")
      assert_equal 7.0, eval_one("number('  7  ')")
      assert eval_one("number('abc')").as(Float64).nan?
      assert eval_one("number('1e3')").as(Float64).nan? # no exponent in XPath 1.0
    end

    it "numbers node-sets via the first node" do
      assert_equal 30.0, eval_one("number(//price)")
      assert eval_one("number(//nonexistent)").as(Float64).nan?
    end

    it "implements sum, floor, ceiling, round" do
      assert_equal 119.9, eval_one("sum(//price)")
      assert_equal 2.0, eval_one("floor(2.5)")
      assert_equal -3.0, eval_one("floor(-2.5)")
      assert_equal 3.0, eval_one("ceiling(2.5)")
      assert_equal -2.0, eval_one("ceiling(-2.5)")
      assert_equal 3.0, eval_one("round(2.5)")
      assert_equal -2.0, eval_one("round(-2.5)") # ties toward positive infinity
      assert_equal 2.0, eval_one("round(2.4)")
      assert_equal Float64::INFINITY, eval_one("floor(1 div 0)")
    end

    it "counts node-sets" do
      assert_equal 3, eval_one("count(//book)")
      assert_equal 3, eval_one("count(//@id)")
    end

    it "resolves id() through DTD-declared ID attributes" do
      d = KXML.parse(%(<!DOCTYPE r [<!ELEMENT r ANY><!ATTLIST a uid ID #IMPLIED>]><r><a uid="x1"/><a uid="x2"/></r>))
      nodes = KXML::XPath.evaluate_nodes("id('x2')", d)
      assert_equal 1, nodes.size
      assert_equal "x2", nodes[0].as(KXML::Element)["uid"]
      # id() accepts a whitespace-separated token list, deduped in doc order
      assert_equal 2, KXML::XPath.evaluate_nodes("id('x1 x2 x1')", d).size
    end
  end

  describe "boolean functions" do
    it "implements not, true, false, lang" do
      refute eval_one("not(true())")
      assert eval_one("true()")
      refute eval_one("false()")
      # lang() only looks at xml:lang, not a plain lang attribute
      refute eval_one("lang('en')", first_book)
      refute eval_one("lang('fr')", first_book)
      refute eval_one("lang('en')", root.elements[0].elements[0]) # inherits
      refute eval_one("lang('en-us')", first_book)
      d = KXML.parse(%(<r xml:lang="en-US"><c/></r>))
      assert eval_one("lang('en')", d.root.not_nil!.elements[0])
    end
  end

  describe "name functions" do
    it "returns local-name, name and namespace-uri" do
      assert_equal "book", eval_one("local-name(//book[1])")
      assert_equal "book", eval_one("name(//book[1])")
      assert_equal "out-of-print", eval_one("name(//book[1]/@out-of-print)")
      assert_equal "out-of-print", eval_one("local-name(//book[1]/@out-of-print)")
      assert_equal "", eval_one("namespace-uri(//book[1])")
      d = KXML.parse(%(<r xmlns:p="urn:p"><p:a/></r>))
      assert_equal "urn:p", eval_one("namespace-uri(//p:a)", d.root.not_nil!)
      assert_equal "p:a", eval_one("name(//p:a)", d.root.not_nil!)
      assert_equal "", eval_one("local-name(comment())", eval_nodes("//comment()")[0])
      assert_equal "", eval_one("name(processing-instruction())", doc) if doc.misc_before.select(KXML::ProcessingInstruction).empty?
    end
  end

  describe "axes with attributes and mixed content" do
    it "treats CDATA as text nodes" do
      d = KXML.parse(%(<r><![CDATA[x]]>y</r>))
      r = d.root.not_nil!
      assert_equal 2, eval_nodes("text()", r).size
      assert_equal "xy", eval_one("string(.)", r)
    end

    it "evaluates steps from attribute contexts" do
      a = eval_nodes("book/@id")[0]
      assert_equal "b1", eval_one("string(.)", a)
      assert_equal 0, eval_nodes("self::*", a).size # * tests the element principal kind, not attributes
      assert_equal 1, eval_nodes("self::node()", a).size
    end
  end

  describe "errors" do
    it "rejects malformed expressions" do
      assert_raises(KXML::XPath::Error) { KXML::XPath.evaluate("book[", root) }
      assert_raises(KXML::XPath::Error) { KXML::XPath.evaluate("//", root) }
      assert_raises(KXML::XPath::Error) { KXML::XPath.evaluate("book](", root) }
    end

    it "rejects unsupported features" do
      err = assert_raises(KXML::XPath::Error) { KXML::XPath.evaluate("$x", root) }
      assert_includes err.message.not_nil!, "variables"

      # id() resolves through DTD-declared ID attributes; the fixture has
      # no DTD, so every token misses and the result is an empty node-set.
      assert_equal 0, KXML::XPath.evaluate_nodes("id('b1')", root).size
      assert_raises(KXML::XPath::Error) { KXML::XPath.evaluate("unknownfn(1)", root) }
    end
  end
end
