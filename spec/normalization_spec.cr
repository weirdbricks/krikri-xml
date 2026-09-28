require "./spec_helper"

describe KXML::Parser do
  describe "attribute-value normalization (3.3.3)" do
    it "normalizes literal whitespace to spaces in CDATA attributes" do
      doc = KXML.parse(%(<root a="x\ty\nz"/>))
      assert_equal "x y z", doc.root.not_nil!["a"]
    end

    it "preserves whitespace written as character references" do
      doc = KXML.parse(%(<root a="x&#9;y&#10;z"/>))
      assert_equal "x\ty\nz", doc.root.not_nil!["a"]
    end

    it "normalizes whitespace inside entity replacement text as spaces" do
      source = %(<!DOCTYPE root [<!ENTITY e "a&#9;b">]><root a="&e;"/>)
      doc = KXML.parse(source)
      assert_equal "a b", doc.root.not_nil!["a"]
    end

    it "trims and collapses spaces for NMTOKEN-typed attributes" do
      source = %(<!DOCTYPE root [<!ATTLIST root a NMTOKEN "  x  y  ">]><root/>)
      doc = KXML.parse(source)
      assert_equal "x y", doc.root.not_nil!["a"]
    end

    it "leaves CDATA-typed attributes untrimmed" do
      source = %(<!DOCTYPE root [<!ATTLIST root a CDATA "  x  ">]><root/>)
      doc = KXML.parse(source)
      assert_equal "  x  ", doc.root.not_nil!["a"]
    end

    it "defaults undeclared attributes to CDATA" do
      doc = KXML.parse(%(<root a="  x  "/>))
      assert_equal "  x  ", doc.root.not_nil!["a"]
    end

    it "normalizes attribute default values with the declared type" do
      source = %(<!DOCTYPE root [<!ATTLIST root a NMTOKENS #FIXED " x   y ">]><root/>)
      doc = KXML.parse(source)
      assert_equal "x y", doc.root.not_nil!["a"]
    end

    it "marks defaulted attributes as not specified" do
      source = %(<!DOCTYPE root [<!ATTLIST root a CDATA "d">]><root/>)
      doc = KXML.parse(source)
      a = doc.root.not_nil!.attribute("a").not_nil!
      refute a.specified?
      assert_equal "d", a.value
    end

    it "marks explicitly written attributes as specified" do
      source = %(<!DOCTYPE root [<!ATTLIST root a CDATA "d">]><root a="x"/>)
      doc = KXML.parse(source)
      a = doc.root.not_nil!.attribute("a").not_nil!
      assert a.specified?
      assert_equal "x", a.value
    end
  end
end
