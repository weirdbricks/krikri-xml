require "./spec_helper"

describe KXML::Parser do
  describe "basic documents" do
    it "parses a simple document" do
      doc = KXML.parse(%(<root><child>hello</child></root>))
      root = doc.root.should_not be_nil
      root.name.should eq("root")
      children = root.elements
      children.size.should eq(1)
      children[0].name.should eq("child")
      children[0].text_content.should eq("hello")
    end

    it "parses empty-element tags" do
      doc = KXML.parse(%(<root><a/><b /></root>))
      root = doc.root.should_not be_nil
      root.elements.size.should eq(2)
      root.elements[0].children.should be_empty
      root.elements[1].children.should be_empty
    end

    it "merges adjacent text nodes" do
      doc = KXML.parse(%(<root>ab<![CDATA[c]]>d</root>))
      root = doc.root.should_not be_nil
      texts = root.children.select(KXML::Text)
      texts.size.should eq(2)
      texts[0].content.should eq("ab")
      texts[1].content.should eq("d")
      cdatas = root.children.select(KXML::CData)
      cdatas.size.should eq(1)
      cdatas[0].content.should eq("c")
    end

    it "preserves whitespace in text" do
      doc = KXML.parse(%(<root>  spaced\tout  </root>))
      root = doc.root.should_not be_nil
      root.text_content.should eq("  spaced\tout  ")
    end

    it "parses attributes in both quote styles" do
      doc = KXML.parse(%(<root a="1" b='2' />))
      root = doc.root.should_not be_nil
      root["a"].should eq("1")
      root["b"].should eq("2")
    end

    it "allows '>' raw in text and attribute values" do
      doc = KXML.parse(%(<root a="x>y">b>c</root>))
      root = doc.root.should_not be_nil
      root["a"].should eq("x>y")
      root.text_content.should eq("b>c")
    end

    it "collects prolog and epilog comments and PIs" do
      doc = KXML.parse(%(<!--before--><?pi one?><!--mid--><root/><!--after-->))
      doc.misc_before.size.should eq(3)
      doc.misc_after.size.should eq(1)
      pi = doc.misc_before[1].should be_a(KXML::ProcessingInstruction)
      pi.target.should eq("pi")
      pi.content.should eq("one")
    end

    it "parses comments and PIs inside content" do
      doc = KXML.parse(%(<root><!--c--><?p data?><!--d--></root>))
      root = doc.root.should_not be_nil
      root.children.size.should eq(3)
      root.children[0].as(KXML::Comment).content.should eq("c")
      root.children[2].as(KXML::Comment).content.should eq("d")
    end

    it "accepts '--->' as a comment terminator" do
      doc = KXML.parse(%(<root><!--a---></root>))
      root = doc.root.should_not be_nil
      root.children[0].as(KXML::Comment).content.should eq("a-")
      doc = KXML.parse(%(<root><!-- a --></root>))
      doc.root.not_nil!.children[0].as(KXML::Comment).content.should eq(" a ")
    end

    it "handles ']]' inside CDATA sections" do
      doc = KXML.parse(%(<root><![CDATA[a]]]b]]></root>))
      root = doc.root.should_not be_nil
      root.children[0].as(KXML::CData).content.should eq("a]]]b")
    end

    it "normalizes CRLF and lone CR line breaks" do
      doc = KXML.parse("<root>a\r\nb\rc\nd</root>")
      root = doc.root.should_not be_nil
      root.text_content.should eq("a\nb\nc\nd")
    end

    it "skips a leading byte order mark" do
      doc = KXML.parse("\u{FEFF}<root/>")
      doc.root.should_not be_nil
    end

    it "parses a document with a DOCTYPE and no subset" do
      doc = KXML.parse(%(<!DOCTYPE root SYSTEM "doc.dtd"><root/>))
      dt = doc.doctype.should_not be_nil
      dt.name.should eq("root")
      dt.system_id.should eq("doc.dtd")
      dt.public_id.should be_nil
    end

    it "parses a PUBLIC doctype" do
      doc = KXML.parse(%(<!DOCTYPE root PUBLIC "pub-id" "sys-id"><root/>))
      dt = doc.doctype.should_not be_nil
      dt.public_id.should eq("pub-id")
      dt.system_id.should eq("sys-id")
    end

    it "round-trips through to_xml" do
      source = %(<root a="1&amp;2"><b>x</b><c/><!--z--></root>)
      doc = KXML.parse(source)
      doc.to_xml.should eq(%(<root a="1&amp;2"><b>x</b><c/><!--z--></root>))
    end

    it "exposes namespace URI on xml: attributes" do
      doc = KXML.parse(%(<root xml:lang="en"/>))
      a = doc.root.not_nil!.attribute("xml:lang").should_not be_nil
      a.namespace_uri.should eq(KXML::XML_NAMESPACE_URI)
    end

    it "handles multibyte characters in text across entity expansions" do
      # Regression: the scanner indexes sources by byte offset; a char-indexed
      # decode silently dropped characters after any multibyte char.
      source = %(<!DOCTYPE root [<!ENTITY pub "&#xc9;ditions">]><root>&pub; suite</root>)
      doc = KXML.parse(source)
      doc.root.not_nil!.text_content.should eq("\u{C9}ditions suite")
    end

    it "handles multibyte characters in attribute values and defaults" do
      source = %(<!DOCTYPE root [<!ATTLIST root a CDATA "caf\u{E9}">]><root b="na\u{EF}ve"/>)
      doc = KXML.parse(source)
      root = doc.root.not_nil!
      root["b"].should eq("na\u{EF}ve")
      root["a"].should eq("caf\u{E9}")
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
      expect_error(%(<root>a]]&gt;]]&gt;]]&gt;b</root>), "']]>'")
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
      doc.root.not_nil!.children[0].as(KXML::CData).content.should eq("a]]")
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

    it "rejects an XML version other than 1.0" do
      expect_error(%(<?xml version="1.1"?><root/>), "unsupported XML version")
    end

    it "rejects mismatched quotes in attribute values" do
      expect_error(%(<root a="x'/>), "unterminated")
    end
  end
end
