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
      assert_equal "<r><a/><b>hi</b></r>", root.to_xml
    end

    it "unlinks nodes and inserts siblings" do
      doc = KXML.parse("<r><a/><b/><c/></r>")
      root = doc.root.not_nil!
      b = root.elements[1]
      b.unlink
      assert_equal "<r><a/><c/></r>", root.to_xml
      x = doc.create_element("x")
      root.elements[1].add_prev_sibling(x)
      assert_equal "<r><a/><x/><c/></r>", root.to_xml
      y = doc.create_element("y")
      root.elements[1].add_next_sibling(y)
      assert_equal "<r><a/><x/><y/><c/></r>", root.to_xml
    end

    it "unlinks document-level nodes" do
      doc = KXML.parse("<!--before--><r/><?pi after?>")
      doc.misc_before[0].unlink
      assert_empty doc.misc_before
      doc.root.not_nil!.unlink
      assert_nil doc.root
      assert_equal "<?pi after?>", doc.to_xml
    end

    it "sets text content, replacing the child list" do
      doc = KXML.parse("<r><a>old<extra/></a></r>")
      a = doc.root.not_nil!.elements[0]
      a.text = "new"
      assert_equal "<a>new</a>", a.to_xml
    end

    it "creates elements with Clark-notation namespaces" do
      doc = KXML.parse("<r xmlns:p='urn:p'/>")
      root = doc.root.not_nil!
      e = doc.create_element("{urn:p}child", root)
      root.append_child(e)
      assert_equal "urn:p", e.namespace_uri
      assert_equal "p:child", e.name # in-scope binding reused
      fresh = doc.create_element("{urn:other}kid", root, "ns9")
      root.append_child(fresh)
      assert_equal "ns9:kid", fresh.name
      assert_equal "urn:other", fresh.attribute("xmlns:ns9").not_nil!.value
    end

    it "sets and deletes attributes with Clark notation" do
      doc = KXML.parse("<r xmlns:p='urn:p'/>")
      root = doc.root.not_nil!
      root.set_attribute("{urn:p}a", "1")
      assert_equal "1", root.attribute_value("{urn:p}a")
      assert_equal "1", root["p:a"] # serialized as the in-scope prefix
      root.delete_attribute("{urn:p}a")
      assert_equal 1, root.attributes.size # only xmlns:p remains
    end

    it "computes libxml2-style node paths" do
      doc = KXML.parse("<r><a/><a x='1'/><a/></r>")
      elems = doc.root.not_nil!.elements
      assert_equal "/r/a[1]", elems[0].node_path
      assert_equal "/r/a[2]", elems[1].node_path
      assert_equal "/r/a[3]", elems[2].node_path
      single = KXML.parse("<r><b/></r>").root.not_nil!.elements[0]
      assert_equal "/r/b", single.node_path
    end
  end

  describe "pretty serialization" do
    it "formats element-only parents one child per line" do
      doc = KXML.parse("<r><a><b/><c/></a><d>text</d></r>")
      assert_equal "<r>\n  <a>\n    <b/>\n    <c/>\n  </a>\n  <d>text</d>\n</r>\n", doc.to_xml(pretty: true)
    end

    it "keeps text-bearing parents inline" do
      doc = KXML.parse("<r><a>x<b/></a></r>")
      assert_equal "<r>\n  <a>x<b/></a>\n</r>\n", doc.to_xml(pretty: true)
    end
  end

  describe "XPath namespace map" do
    it "resolves prefixes from the map and matches no-namespace nodes unprefixed" do
      doc = KXML.parse(%(<r xmlns="urn:d"><a/><p:b xmlns:p="urn:p"/></r>))
      root = doc.root.not_nil!
      ns = {"p" => "urn:p"} of String => String
      assert_equal 2, KXML::XPath.evaluate_nodes("*", root, ns_map: ns).size
      assert_equal 1, KXML::XPath.evaluate_nodes("p:b", root, ns_map: ns).size
      # XPath 1.0 section 2.3: unprefixed tests only match no-namespace
      # nodes, with or without an explicit map (a is in the default ns)
      assert_equal 0, KXML::XPath.evaluate_nodes("a", root, ns_map: ns).size
      assert_equal 0, KXML::XPath.evaluate_nodes("a", root).size
    end
  end
end
