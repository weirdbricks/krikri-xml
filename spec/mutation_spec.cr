require "./spec_helper"

# The mutation API, Clark-notation helpers, node paths, libxml2-shaped
# pretty serialization and the XPath namespace map - the surface
# community.general.xml's plugin needs from krikri-xml.
describe KXML do
  describe "mutation API" do
    it "appends children with move semantics" do
      doc = KXML.parse("<r><a/></r>")
      root = doc.root.not_nil!
      b = doc.create_element("b")
      root.append_child(b)
      b.append_child(doc.create_text("hi"))
      root.append_child(b) # moving an already-attached node re-parents it
      root.to_xml.should eq("<r><a/><b>hi</b></r>")
    end

    it "unlinks nodes and inserts siblings" do
      doc = KXML.parse("<r><a/><b/><c/></r>")
      root = doc.root.not_nil!
      b = root.elements[1]
      b.unlink
      root.to_xml.should eq("<r><a/><c/></r>")
      x = doc.create_element("x")
      root.elements[1].add_prev_sibling(x)
      root.to_xml.should eq("<r><a/><x/><c/></r>")
      y = doc.create_element("y")
      root.elements[1].add_next_sibling(y)
      root.to_xml.should eq("<r><a/><x/><y/><c/></r>")
    end

    it "sets text content, replacing the child list" do
      doc = KXML.parse("<r><a>old<extra/></a></r>")
      a = doc.root.not_nil!.elements[0]
      a.text = "new"
      a.to_xml.should eq("<a>new</a>")
    end

    it "creates elements with Clark-notation namespaces" do
      doc = KXML.parse("<r xmlns:p='urn:p'/>")
      root = doc.root.not_nil!
      e = doc.create_element("{urn:p}child", root)
      root.append_child(e)
      e.namespace_uri.should eq("urn:p")
      e.name.should eq("p:child") # in-scope binding reused
      fresh = doc.create_element("{urn:other}kid", root, "ns9")
      root.append_child(fresh)
      fresh.name.should eq("ns9:kid")
      fresh.attribute("xmlns:ns9").not_nil!.value.should eq("urn:other")
    end

    it "sets and deletes attributes with Clark notation" do
      doc = KXML.parse("<r xmlns:p='urn:p'/>")
      root = doc.root.not_nil!
      root.set_attribute("{urn:p}a", "1")
      root.attribute_value("{urn:p}a").should eq("1")
      root["p:a"].should eq("1") # serialized as the in-scope prefix
      root.delete_attribute("{urn:p}a")
      root.attributes.size.should eq(1) # only xmlns:p remains
    end

    it "computes libxml2-style node paths" do
      doc = KXML.parse("<r><a/><a x='1'/><a/></r>")
      elems = doc.root.not_nil!.elements
      elems[0].node_path.should eq("/r/a[1]")
      elems[1].node_path.should eq("/r/a[2]")
      elems[2].node_path.should eq("/r/a[3]")
      single = KXML.parse("<r><b/></r>").root.not_nil!.elements[0]
      single.node_path.should eq("/r/b")
    end
  end

  describe "pretty serialization" do
    it "formats element-only parents one child per line" do
      doc = KXML.parse("<r><a><b/><c/></a><d>text</d></r>")
      doc.to_xml(pretty: true).should eq("<r>\n  <a>\n    <b/>\n    <c/>\n  </a>\n  <d>text</d>\n</r>\n")
    end

    it "keeps text-bearing parents inline" do
      doc = KXML.parse("<r><a>x<b/></a></r>")
      doc.to_xml(pretty: true).should eq("<r>\n  <a>x<b/></a>\n</r>\n")
    end
  end

  describe "XPath namespace map" do
    it "resolves prefixes from the map and matches no-namespace nodes unprefixed" do
      doc = KXML.parse(%(<r xmlns="urn:d"><a/><p:b xmlns:p="urn:p"/></r>))
      root = doc.root.not_nil!
      ns = {"p" => "urn:p"} of String => String
      KXML::XPath.evaluate_nodes("*", root, ns_map: ns).size.should eq(2)
      KXML::XPath.evaluate_nodes("p:b", root, ns_map: ns).size.should eq(1)
      # libxml2 semantics: unprefixed tests only match no-namespace nodes
      KXML::XPath.evaluate_nodes("a", root, ns_map: ns).size.should eq(0)
      KXML::XPath.evaluate_nodes("a", root).size.should eq(1)
    end
  end
end
