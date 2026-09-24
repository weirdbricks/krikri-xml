require "./spec_helper"

describe KXML::Parser do
  describe "the internal DTD subset" do
    it "skips ELEMENT declarations, including quoted '>'" do
      source = %(<!DOCTYPE root [<!ELEMENT root (#PCDATA | a)*><!ELEMENT a EMPTY>]><root/>)
      doc = KXML.parse(source)
      doc.root.should_not be_nil
      doc.doctype.should_not be_nil
    end

    it "rejects references inside ELEMENT declarations" do
      source = %(<!DOCTYPE root [<!ELEMENT root (&e;)>]><root/>)
      ex = expect_raises KXML::Error do
        KXML.parse(source)
      end
      ex.message.not_nil!.should contain("expected a name")
    end

    it "applies ATTLIST defaults" do
      source = %(<!DOCTYPE root [<!ATTLIST root a CDATA "one" b CDATA #IMPLIED>]><root/>)
      doc = KXML.parse(source)
      root = doc.root.not_nil!
      root["a"].should eq("one")
      root.attribute("b").should be_nil
    end

    it "gives the first binding of a multiply-declared attribute precedence" do
      source = %(<!DOCTYPE root [<!ATTLIST root a CDATA "first"><!ATTLIST root a CDATA "second">]><root/>)
      doc = KXML.parse(source)
      doc.root.not_nil!["a"].should eq("first")
    end

    it "expands entities in attribute defaults" do
      source = %(<!DOCTYPE root [<!ENTITY e "val"><!ATTLIST root a CDATA "&e;">]><root/>)
      doc = KXML.parse(source)
      doc.root.not_nil!["a"].should eq("val")
    end

    it "requires entities referenced in defaults to be declared first" do
      source = %(<!DOCTYPE root [<!ATTLIST root a CDATA "&e;"><!ENTITY e "val">]><root/>)
      ex = expect_raises KXML::Error do
        KXML.parse(source)
      end
      ex.message.not_nil!.should contain("is not declared")
    end

    it "parses enumerated attribute types" do
      source = %(<!DOCTYPE root [<!ATTLIST root a (one | two) "two">]><root/>)
      doc = KXML.parse(source)
      doc.root.not_nil!["a"].should eq("two")
    end

    it "parses NOTATION attribute types" do
      source = %(<!DOCTYPE root [<!NOTATION n SYSTEM "x"><!ATTLIST root a NOTATION (n) #IMPLIED>]><root/>)
      doc = KXML.parse(source)
      doc.root.should_not be_nil
    end

    it "expands parameter entities at declaration positions" do
      source = %(<!DOCTYPE root [<!ENTITY % decl '<!ENTITY inner "value">'>%decl;]><root>&inner;</root>)
      doc = KXML.parse(source)
      doc.root.not_nil!.text_content.should eq("value")
    end

    it "rejects PE references inside entity values in the internal subset (WFC)" do
      # 4.4.5's YN example involves a PE reference inside an EntityValue;
      # in the internal subset the WFC "PEs in Internal Subset" forbids it
      # (IBM not-wf-P29-ibm29n04 in the conformance suite expects not-wf).
      source = %(<!DOCTYPE root [<!ENTITY % YN '"Yes"'><!ENTITY WhatHeSaid "He said %YN;">]><root>&WhatHeSaid;</root>)
      ex = expect_raises KXML::Error do
        KXML.parse(source)
      end
      ex.message.not_nil!.should contain("parameter entity references cannot occur")
    end

    it "rejects PE references inside entity values even when the PE was declared via an escaped percent" do
      # The inner % must be escaped as a character reference to declare the
      # nested PE, but any PE reference inside an EntityValue in the
      # internal subset is still forbidden by the WFC "PEs in Internal
      # Subset" (IBM not-wf-P29-ibm29n04 expects not-wf).
      source = %(<!DOCTYPE root [<!ENTITY % a '<!ENTITY &#37; b "y">'>%a;<!ENTITY c "%b;">]><root>&c;</root>)
      ex = expect_raises KXML::Error do
        KXML.parse(source)
      end
      ex.message.not_nil!.should contain("parameter entity references cannot occur")
    end

    it "rejects bare '%' in entity values" do
      source = %(<!DOCTYPE root [<!ENTITY e "100%">]><root/>)
      expect_raises KXML::Error do
        KXML.parse(source)
      end
    end

    it "rejects unterminated internal subsets" do
      source = %(<!DOCTYPE root [<!ENTITY e "x"><root/>)
      expect_raises KXML::Error do
        KXML.parse(source)
      end
    end

    it "rejects junk in the internal subset" do
      source = %(<!DOCTYPE root [junk]><root/>)
      expect_raises KXML::Error do
        KXML.parse(source)
      end
    end

    it "accepts comments and PIs in the internal subset" do
      source = %(<!DOCTYPE root [<!-- c --><?p d?><!ENTITY e "v">]><root>&e;</root>)
      doc = KXML.parse(source)
      doc.root.not_nil!.text_content.should eq("v")
    end

    it "supports an XML declaration with encoding and standalone" do
      doc = KXML.parse(%(<?xml version="1.0" encoding="UTF-8" standalone="yes"?><root/>))
      doc.root.should_not be_nil
    end

    it "rejects an invalid encoding name" do
      expect_raises KXML::Error do
        KXML.parse(%(<?xml version="1.0" encoding="1bad"?><root/>))
      end
    end
  end
end
