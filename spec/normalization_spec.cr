require "./spec_helper"

describe KXML::Parser do
  describe "attribute-value normalization (3.3.3)" do
    it "normalizes literal whitespace to spaces in CDATA attributes" do
      doc = KXML.parse(%(<root a="x\ty\nz"/>))
      doc.root.not_nil!["a"].should eq("x y z")
    end

    it "preserves whitespace written as character references" do
      doc = KXML.parse(%(<root a="x&#9;y&#10;z"/>))
      doc.root.not_nil!["a"].should eq("x\ty\nz")
    end

    it "normalizes whitespace inside entity replacement text as spaces" do
      source = %(<!DOCTYPE root [<!ENTITY e "a&#9;b">]><root a="&e;"/>)
      doc = KXML.parse(source)
      doc.root.not_nil!["a"].should eq("a b")
    end

    it "trims and collapses spaces for NMTOKEN-typed attributes" do
      source = %(<!DOCTYPE root [<!ATTLIST root a NMTOKEN "  x  y  ">]><root/>)
      doc = KXML.parse(source)
      doc.root.not_nil!["a"].should eq("x y")
    end

    it "leaves CDATA-typed attributes untrimmed" do
      source = %(<!DOCTYPE root [<!ATTLIST root a CDATA "  x  ">]><root/>)
      doc = KXML.parse(source)
      doc.root.not_nil!["a"].should eq("  x  ")
    end

    it "defaults undeclared attributes to CDATA" do
      doc = KXML.parse(%(<root a="  x  "/>))
      doc.root.not_nil!["a"].should eq("  x  ")
    end

    it "normalizes attribute default values with the declared type" do
      source = %(<!DOCTYPE root [<!ATTLIST root a NMTOKENS #FIXED " x   y ">]><root/>)
      doc = KXML.parse(source)
      doc.root.not_nil!["a"].should eq("x y")
    end

    it "marks defaulted attributes as not specified" do
      source = %(<!DOCTYPE root [<!ATTLIST root a CDATA "d">]><root/>)
      doc = KXML.parse(source)
      a = doc.root.not_nil!.attribute("a").should_not be_nil
      a.specified?.should be_false
      a.value.should eq("d")
    end

    it "marks explicitly written attributes as specified" do
      source = %(<!DOCTYPE root [<!ATTLIST root a CDATA "d">]><root a="x"/>)
      doc = KXML.parse(source)
      a = doc.root.not_nil!.attribute("a").should_not be_nil
      a.specified?.should be_true
      a.value.should eq("x")
    end
  end
end
