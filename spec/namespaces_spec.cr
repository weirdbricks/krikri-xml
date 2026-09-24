require "./spec_helper"

describe KXML::Parser do
  describe "namespaces" do
    it "resolves the default namespace for elements but not attributes" do
      doc = KXML.parse(%(<root xmlns="urn:a"><child attr="v"/></root>))
      root = doc.root.not_nil!
      root.namespace_uri.should eq("urn:a")
      child = root.elements[0]
      child.namespace_uri.should eq("urn:a")
      child.attribute("attr").not_nil!.namespace_uri.should be_nil
    end

    it "resolves prefixed namespaces" do
      doc = KXML.parse(%(<r xmlns:p="urn:p"><p:e p:a="1"/></r>))
      e = doc.root.not_nil!.elements[0]
      e.namespace_uri.should eq("urn:p")
      e.local_name.should eq("e")
      e.prefix.should eq("p")
      e.attribute("p:a").not_nil!.namespace_uri.should eq("urn:p")
    end

    it "supports re-declaring prefixes in nested scopes" do
      doc = KXML.parse(%(<r xmlns:p="urn:outer"><c xmlns:p="urn:inner"><p:g/></c><p:h/></r>))
      root = doc.root.not_nil!
      root.elements[0].elements[0].namespace_uri.should eq("urn:inner")
      root.elements[1].namespace_uri.should eq("urn:outer")
    end

    it "supports undeclaring the default namespace" do
      doc = KXML.parse(%(<r xmlns="urn:a"><c xmlns=""><g/></c></r>))
      g = doc.root.not_nil!.elements[0].elements[0]
      g.namespace_uri.should be_nil
    end

    it "treats unprefixed attributes as having no namespace even with a default" do
      doc = KXML.parse(%(<r xmlns="urn:a" a="1"/>))
      doc.root.not_nil!.attribute("a").not_nil!.namespace_uri.should be_nil
    end

    it "binds the xml prefix implicitly" do
      doc = KXML.parse(%(<r xml:space="preserve"/>))
      a = doc.root.not_nil!.attribute("xml:space").not_nil!
      a.namespace_uri.should eq(KXML::XML_NAMESPACE_URI)
    end

    it "gives xmlns declarations the xmlns namespace URI" do
      doc = KXML.parse(%(<r xmlns="urn:a" xmlns:p="urn:p"/>))
      root = doc.root.not_nil!
      root.attribute("xmlns").not_nil!.namespace_uri.should eq(KXML::XMLNS_NAMESPACE_URI)
      root.attribute("xmlns:p").not_nil!.namespace_uri.should eq(KXML::XMLNS_NAMESPACE_URI)
    end

    it "rejects undeclared prefixes on elements" do
      ex = expect_raises KXML::Error do
        KXML.parse(%(<p:e xmlns:p="urn:p"><q:f/></p:e>))
      end
      ex.message.not_nil!.should contain("has not been declared")
    end

    it "rejects undeclared prefixes on attributes" do
      ex = expect_raises KXML::Error do
        KXML.parse(%(<r a="1" q:a="2"/>))
      end
      ex.message.not_nil!.should contain("has not been declared")
    end

    it "rejects redeclaring the xmlns prefix" do
      expect_raises KXML::Error do
        KXML.parse(%(<r xmlns:xmlns="urn:x"/>))
      end
    end

    it "rejects binding the xml prefix to a foreign URI" do
      expect_raises KXML::Error do
        KXML.parse(%(<r xmlns:xml="urn:wrong"/>))
      end
    end

    it "rejects empty URIs on prefixed declarations" do
      expect_raises KXML::Error do
        KXML.parse(%(<r xmlns:p=""/>))
      end
    end

    it "rejects namespace conflicts between attributes" do
      source = %(<r xmlns:p="urn:a" xmlns:q="urn:a" p:x="1" q:x="2"/>)
      ex = expect_raises KXML::Error do
        KXML.parse(source)
      end
      ex.message.not_nil!.should contain("conflict")
    end

    it "resolves DTD default attributes through namespaces" do
      source = %(<!DOCTYPE r [<!ATTLIST r p:a CDATA "v">]><r xmlns:p="urn:p"/>)
      doc = KXML.parse(source)
      a = doc.root.not_nil!.attribute("p:a").should_not be_nil
      a.namespace_uri.should eq("urn:p")
      a.specified?.should be_false
    end
  end
end
