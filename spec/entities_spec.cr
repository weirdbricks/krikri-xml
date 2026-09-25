require "./spec_helper"

describe KXML::Parser do
  describe "entities" do
    it "expands predefined entities in text" do
      doc = KXML.parse(%(<root>&lt;&gt;&amp;&apos;&quot;</root>))
      doc.root.not_nil!.text_content.should eq("<>&'\"")
    end

    it "expands numeric and hex character references" do
      doc = KXML.parse(%(<root>&#65;&#x42;&#x1F600;</root>))
      doc.root.not_nil!.text_content.should eq("AB" + 0x1F600.chr)
    end

    it "preserves character references for whitespace in text" do
      doc = KXML.parse(%(<root>a&#9;b&#10;c&#13;d</root>))
      doc.root.not_nil!.text_content.should eq("a\tb\nc\rd")
    end

    it "expands declared internal entities" do
      doc = KXML.parse(%(<!DOCTYPE root [<!ENTITY e "value">]><root>&e;</root>))
      doc.root.not_nil!.text_content.should eq("value")
    end

    it "re-parses markup inside entity replacement text (spec appendix D)" do
      doc = KXML.parse(%(<!DOCTYPE root [<!ENTITY e "<p>hi</p>">]><root>&e;</root>))
      root = doc.root.not_nil!
      p_elem = root.elements[0]
      p_elem.name.should eq("p")
      p_elem.text_content.should eq("hi")
    end

    it "keeps the ampersand from an expanded reference as data (4.4.2)" do
      doc = KXML.parse(%(<!DOCTYPE root [<!ENTITY e "AT&amp;T;">]><root>&e;</root>))
      doc.root.not_nil!.text_content.should eq("AT&T;")
    end

    it "constructs replacement text per section 4.5 (char refs expanded, general refs bypassed)" do
      # The %pub; parameter-entity part of the spec's example is omitted:
      # PE references inside EntityValues in the internal subset are
      # forbidden by the WFC "PEs in Internal Subset" (IBM
      # not-wf-P29-ibm29n04 in the conformance suite expects not-wf).
      source = %(<!DOCTYPE root [<!ENTITY rights "All rights reserved"><!ENTITY book "La Peste: Albert Camus, &#xA9; 1947. &rights;">]><root>&book;</root>)
      doc = KXML.parse(source)
      doc.root.not_nil!.text_content.should eq("La Peste: Albert Camus, \u{A9} 1947. All rights reserved")
    end

    it "handles the appendix D double-escaping example" do
      source = %(<!DOCTYPE root [<!ENTITY example "<p>An ampersand (&#38;#38;) may be escaped numerically (&#38;#38;#38;) or with a general entity (&amp;amp;).</p>">]><root>&example;</root>)
      doc = KXML.parse(source)
      p_elem = doc.root.not_nil!.elements[0]
      p_elem.text_content.should eq("An ampersand (&) may be escaped numerically (&#38;) or with a general entity (&amp;).")
    end

    it "uses the first declaration when an entity is declared twice" do
      doc = KXML.parse(%(<!DOCTYPE root [<!ENTITY e "first"><!ENTITY e "second">]><root>&e;</root>))
      doc.root.not_nil!.text_content.should eq("first")
    end

    it "expands the empty entity to nothing" do
      doc = KXML.parse(%(<!DOCTYPE root [<!ENTITY e "">]><root>a&e;b</root>))
      doc.root.not_nil!.text_content.should eq("ab")
    end

    it "expands predefined entities in attribute values" do
      doc = KXML.parse(%(<root a="&lt;&amp;"/>))
      doc.root.not_nil!["a"].should eq("<&")
    end

    it "expands declared entities in attribute values (4.4.5)" do
      # General-entity variant of the 4.4.5 example: the bypassed &YN;
      # reference expands when WhatHeSaid is used, quotes treated as data.
      source = %(<!DOCTYPE root [<!ENTITY YN '"Yes"'><!ENTITY WhatHeSaid "He said &YN;">]><root a="&WhatHeSaid;"/>)
      doc = KXML.parse(source)
      doc.root.not_nil!["a"].should eq(%(He said "Yes"))
    end

    it "treats quotes in expanded replacement text as data (4.4.5)" do
      source = %(<!DOCTYPE root [<!ENTITY EndAttr "27'">]><root a='a-&EndAttr;-b'/>)
      doc = KXML.parse(source)
      doc.root.not_nil!["a"].should eq("a-27'-b")
    end

    it "applies 3.3.3 to entities recursively in attribute values" do
      source = %(<!DOCTYPE root [<!ENTITY ws "a b">]><root a="&ws;"/>)
      doc = KXML.parse(source)
      doc.root.not_nil!["a"].should eq("a b")
    end

    it "expands entities recursively in content" do
      source = %(<!DOCTYPE root [<!ENTITY a "&b;"><!ENTITY b "deep">]><root>&a;</root>)
      doc = KXML.parse(source)
      doc.root.not_nil!.text_content.should eq("deep")
    end

    it "treats undeclared references after parameter entities as validity errors" do
      source = %(<!DOCTYPE foo [<!ENTITY % pe "<!ENTITY ent1 'text'>">%pe;]><foo>&ent2;</foo>)
      doc = KXML.parse(source)
      doc.root.not_nil!.text_content.should eq("")
    end

    it "allows a bypassed reference to an undeclared entity inside an entity value" do
      # Bypassed: left as-is; only expanded if the outer entity is used
      source = %(<!DOCTYPE root [<!ENTITY e "&nope;">]><root>&e;</root>)
      ex = expect_raises KXML::Error do
        KXML.parse(source)
      end
      ex.message.not_nil!.should contain("'nope' is not declared")
    end

    it "rejects a literal '<' produced by an entity in an attribute value" do
      source = %(<!DOCTYPE root [<!ENTITY x "&#60;">]><root a="&x;"/>)
      ex = expect_raises KXML::Error do
        KXML.parse(source)
      end
      ex.message.not_nil!.should contain("'<'")
    end

    it "rejects the 4.4.5 non-well-formed attribute example" do
      source = %(<!DOCTYPE root [<!ENTITY EndAttr "27'">]><root a='a-&EndAttr;>')
      expect_raises KXML::Error do
        KXML.parse(source)
      end
    end

    it "rejects undeclared parameter entities in entity values" do
      source = %(<!DOCTYPE root [<!ENTITY e "%pe;">]><root/>)
      ex = expect_raises KXML::Error do
        KXML.parse(source)
      end
      ex.message.not_nil!.should contain("parameter entity references cannot occur")
    end

    it "rejects references to external entities in content" do
      source = %(<!DOCTYPE root [<!ENTITY e SYSTEM "x.ent">]><root>&e;</root>)
      ex = expect_raises KXML::Error do
        KXML.parse(source)
      end
      ex.message.not_nil!.should contain("external")
    end

    it "rejects external entity references in attribute values" do
      source = %(<!DOCTYPE root [<!ENTITY e SYSTEM "x.ent">]><root a="&e;"/>)
      ex = expect_raises KXML::Error do
        KXML.parse(source)
      end
      ex.message.not_nil!.should contain("external")
    end

    it "rejects references to unparsed entities in content" do
      source = %(<!DOCTYPE root [<!ENTITY e SYSTEM "x.png" NDATA png><!NOTATION png SYSTEM "png.exe">]><root>&e;</root>)
      ex = expect_raises KXML::Error do
        KXML.parse(source)
      end
      ex.message.not_nil!.should contain("external")
    end

    it "enforces the entity expansion depth limit" do
      decls = String.build do |b|
        100.times do |i|
          next_name = i == 99 ? "x" : "e#{i + 1}"
          b << "<!ENTITY e#{i} \"&#{next_name};\">"
        end
      end
      source = %(<!DOCTYPE root [#{decls}]><root>&e0;</root>)
      ex = expect_raises KXML::Error do
        KXML.parse(source)
      end
      ex.message.not_nil!.should contain("nested too deeply")
    end

    it "rejects unterminated entity values" do
      source = %(<!DOCTYPE root [<!ENTITY e "oops>]><root/>)
      expect_raises KXML::Error do
        KXML.parse(source)
      end
    end
  end
end
