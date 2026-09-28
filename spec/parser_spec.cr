require "./spec_helper"

describe KXML::Parser do
  describe "basic documents" do
    it "parses a simple document" do
      doc = KXML.parse(%(<root><child>hello</child></root>))
      root = doc.root.not_nil!
      assert_equal "root", root.name
      children = root.elements
      assert_equal 1, children.size
      assert_equal "child", children[0].name
      assert_equal "hello", children[0].text_content
    end

    it "parses empty-element tags" do
      doc = KXML.parse(%(<root><a/><b /></root>))
      root = doc.root.not_nil!
      assert_equal 2, root.elements.size
      assert_empty root.elements[0].children
      assert_empty root.elements[1].children
    end

    it "merges adjacent text nodes" do
      doc = KXML.parse(%(<root>ab<![CDATA[c]]>d</root>))
      root = doc.root.not_nil!
      texts = root.children.select(KXML::Text)
      assert_equal 2, texts.size
      assert_equal "ab", texts[0].content
      assert_equal "d", texts[1].content
      cdatas = root.children.select(KXML::CData)
      assert_equal 1, cdatas.size
      assert_equal "c", cdatas[0].content
    end

    it "preserves whitespace in text" do
      doc = KXML.parse(%(<root>  spaced\tout  </root>))
      root = doc.root.not_nil!
      assert_equal "  spaced\tout  ", root.text_content
    end

    it "parses attributes in both quote styles" do
      doc = KXML.parse(%(<root a="1" b='2' />))
      root = doc.root.not_nil!
      assert_equal "1", root["a"]
      assert_equal "2", root["b"]
    end

    it "allows '>' raw in text and attribute values" do
      doc = KXML.parse(%(<root a="x>y">b>c</root>))
      root = doc.root.not_nil!
      assert_equal "x>y", root["a"]
      assert_equal "b>c", root.text_content
    end

    it "collects prolog and epilog comments and PIs" do
      doc = KXML.parse(%(<!--before--><?pi one?><!--mid--><root/><!--after-->))
      assert_equal 3, doc.misc_before.size
      assert_equal 1, doc.misc_after.size
      pi = doc.misc_before[1].as(KXML::ProcessingInstruction)
      assert_equal "pi", pi.target
      assert_equal "one", pi.content
    end

    it "parses comments and PIs inside content" do
      doc = KXML.parse(%(<root><!--c--><?p data?><!--d--></root>))
      root = doc.root.not_nil!
      assert_equal 3, root.children.size
      assert_equal "c", root.children[0].as(KXML::Comment).content
      assert_equal "d", root.children[2].as(KXML::Comment).content
    end

    it "accepts '-->' terminators but rejects content ending with a lone dash" do
      doc = KXML.parse(%(<root><!-- a --></root>))
      assert_equal " a ", doc.root.not_nil!.children[0].as(KXML::Comment).content
      # A comment ending with three dashes is not well-formed (Clark
      # xmltest not-wf-sa-070): the trailing '-' cannot fit the grammar.
      expect_error(%(<!--a---><doc/>), "comment")
    end

    it "handles ']]' inside CDATA sections" do
      doc = KXML.parse(%(<root><![CDATA[a]]]b]]></root>))
      root = doc.root.not_nil!
      assert_equal "a]]]b", root.children[0].as(KXML::CData).content
    end

    it "normalizes CRLF and lone CR line breaks" do
      doc = KXML.parse("<root>a\r\nb\rc\nd</root>")
      root = doc.root.not_nil!
      assert_equal "a\nb\nc\nd", root.text_content
    end

    it "skips a leading byte order mark" do
      doc = KXML.parse("\u{FEFF}<root/>")
      refute_nil doc.root
    end

    it "rejects encodings incompatible with the document input" do
      expect_error(%(<?xml version="1.0" encoding="UTF-16"?><root/>), "incompatible")
      expect_error("\u{FEFF}<?xml version='1.0' encoding='iso-8859-1'?><root/>", "conflicts")
    end

    it "parses a document with a DOCTYPE and no subset" do
      doc = KXML.parse(%(<!DOCTYPE root SYSTEM "doc.dtd"><root/>))
      dt = doc.doctype.not_nil!
      assert_equal "root", dt.name
      assert_equal "doc.dtd", dt.system_id
      assert_nil dt.public_id
    end

    it "parses a PUBLIC doctype" do
      doc = KXML.parse(%(<!DOCTYPE root PUBLIC "pub-id" "sys-id"><root/>))
      dt = doc.doctype.not_nil!
      assert_equal "pub-id", dt.public_id
      assert_equal "sys-id", dt.system_id
    end

    it "round-trips through to_xml" do
      source = %(<root a="1&amp;2"><b>x</b><c/><!--z--></root>)
      doc = KXML.parse(source)
      assert_equal %(<root a="1&amp;2"><b>x</b><c/><!--z--></root>), doc.to_xml
    end

    it "exposes namespace URI on xml: attributes" do
      doc = KXML.parse(%(<root xml:lang="en"/>))
      a = doc.root.not_nil!.attribute("xml:lang").not_nil!
      assert_equal KXML::XML_NAMESPACE_URI, a.namespace_uri
    end

    it "handles multibyte characters in text across entity expansions" do
      # Regression: the scanner indexes sources by byte offset; a char-indexed
      # decode silently dropped characters after any multibyte char.
      source = %(<!DOCTYPE root [<!ENTITY pub "&#xc9;ditions">]><root>&pub; suite</root>)
      doc = KXML.parse(source)
      assert_equal "\u{C9}ditions suite", doc.root.not_nil!.text_content
    end

    it "handles multibyte characters in attribute values and defaults" do
      source = %(<!DOCTYPE root [<!ATTLIST root a CDATA "caf\u{E9}">]><root b="na\u{EF}ve"/>)
      doc = KXML.parse(source)
      root = doc.root.not_nil!
      assert_equal "na\u{EF}ve", root["b"]
      assert_equal "caf\u{E9}", root["a"]
    end
  end

  describe "well-formedness errors" do
    it "rejects mismatched end tags" do
      expect_error(%(<root><a></b></root>), "mismatched")
    end

    it "rejects case-mismatched end tags" do
      expect_error(%(<root></Root>), "mismatched")
    end

    it "rejects unclosed elements" do
      expect_error(%(<root><a></root>), "mismatched")
    end

    it "rejects documents without a root" do
      expect_error(%(<!-- just a comment -->), "root")
    end

    it "rejects text before the root" do
      expect_error(%(hello<root/>), "before")
    end

    it "rejects elements after the root" do
      expect_error(%(<root/><other/>), "after")
    end

    it "rejects text after the root" do
      expect_error(%(<root/>trailing), "after")
    end

    it "rejects duplicate attributes" do
      expect_error(%(<root a="1" a="2"/>), "duplicate")
    end

    it "rejects attributes without a preceding space" do
      expect_error(%(<root a="1"b="2"/>), "whitespace is required")
    end

    it "rejects '<' in attribute values" do
      expect_error(%(<root a="<x"/>), "not allowed")
    end

    it "rejects undeclared entity references" do
      expect_error(%(<root>&nope;</root>), "not declared")
    end

    it "rejects bare ampersands in text" do
      expect_error(%(<root>a & b</root>))
    end

    it "rejects bare ampersands in attribute values" do
      expect_error(%(<root a="x & y"/>))
    end

    it "rejects unterminated entity references" do
      expect_error(%(<root>&amp</root>), "unterminated")
    end

    it "rejects character references to invalid XML characters" do
      expect_error(%(<root>&#0;</root>), "invalid XML character")
      expect_error(%(<root>&#xFFFF;</root>), "invalid XML character")
    end

    it "rejects out-of-range character references" do
      expect_error(%(<root>&#x110000;</root>), "out of range")
    end

    it "rejects character references without digits" do
      expect_error(%(<root>&#;</root>), "no digits")
      expect_error(%(<root>&#x;</root>), "no digits")
    end

    it "rejects '--' inside comments" do
      expect_error(%(<root><!-- a -- b --></root>), "'--'")
    end

    it "rejects ']]>' in text" do
      expect_error(%(<root>a]]>b</root>), "']]>'")
    end

    it "rejects ']]>' in text written literally" do
      expect_error(%(<root>a]]>"</root>), "']]>'")
    end

    it "rejects unterminated CDATA sections" do
      expect_error(%(<root><![CDATA[oops</root>), "CDATA")
    end

    it "rejects ']]>' split across CDATA sections is fine but not in one" do
      # ']]' then ']]>' forms the terminator for the first section
      doc = KXML.parse(%(<root><![CDATA[a]]]]><![CDATA[b]]></root>))
      assert_equal "a]]", doc.root.not_nil!.children[0].as(KXML::CData).content
    end

    it "rejects '<!' in content" do
      expect_error(%(<root><!foo></root>), "'<!'")
    end

    it "rejects unterminated comments" do
      expect_error(%(<root><!-- oops</root>), "unterminated comment")
    end

    it "rejects unterminated attribute values" do
      expect_error(%(<root a="oops>), "unterminated")
    end

    it "rejects invalid element names" do
      expect_error(%(<1root/>))
      expect_error(%(<root sub/>), "'='")
    end

    it "rejects invalid XML characters" do
      expect_error(%(<root>\u{1}</root>), "invalid XML character")
    end

    it "rejects processing instructions targeting 'xml'" do
      expect_error(%(<root><?XML version="1.0"?></root>))
    end

    it "rejects a second XML declaration anywhere" do
      expect_error(%(<?xml version="1.0"?><root/><?xml version="1.0"?>))
    end

    it "accepts any 1.x XML version but rejects others" do
      doc = KXML.parse(%(<?xml version="1.1"?><root/>))
      refute_nil doc.root
      expect_error(%(<?xml version="2.0"?><root/>), "unsupported XML version")
    end

    it "rejects mismatched quotes in attribute values" do
      expect_error(%(<root a="x'/>), "unterminated")
    end
  end
end
