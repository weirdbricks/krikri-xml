require "./spec_helper"

# Document-order allocation and the lazy-renumbering protocol behind it.
#
# XPath node-sets are sorted and deduplicated solely via doc_order, so the
# invariants here are what keep XPath results correct on mutated documents:
# orders must be strictly increasing in traversal order after any renumber
# pass, and a dirty document (insertions that landed before existing nodes)
# must renumber before any order-dependent read - XPath does this at
# evaluation entry.

def collect_orders(node : KXML::Node, orders : Array(Int32)) : Nil
  orders << node.doc_order if node.is_a?(KXML::Element)
  node.children.each { |child| collect_orders(child, orders) } if node.is_a?(KXML::Element) || node.is_a?(KXML::Document)
end

def element_orders(doc : KXML::Document) : Array(Int32)
  orders = [] of Int32
  collect_orders(doc, orders)
  orders
end

def assert_increasing(orders : Array(Int32)) : Nil
  orders.each_cons(2) { |pair| pair[1].should be > pair[0] }
end

describe "document order" do
  it "keeps append_child appends strictly ordered (fast path)" do
    doc = KXML.parse("<root><a/><b/></root>")
    root = doc.root.as(KXML::Element)
    100.times { |i| root.append_child(doc.create_element("n#{i}")) }
    assert_increasing(element_orders(doc))
    KXML::XPath.evaluate_nodes("/root/n99", doc.root.as(KXML::Element)).size.should eq(1)
  end

  it "orders attributes created before their element is attached" do
    doc = KXML.parse("<root/>")
    root = doc.root.as(KXML::Element)
    50.times do |i|
      e = doc.create_element("item")
      e.set_attribute("id", i.to_s)
      root.append_child(e)
    end
    # Attribute doc_order must land between its element and the next one.
    items = KXML::XPath.evaluate_nodes("/root/item", doc.root.as(KXML::Element))
    items.size.should eq(50)
    ids = items.map { |item| item.as(KXML::Element)["id"]? || "" }
    ids.should eq((0...50).map(&.to_s))
    # Every attribute's order sits inside its element's subtree range.
    root.elements.each_cons(2) do |pair|
      a = pair[0].attributes.first
      a.doc_order.should be > pair[0].doc_order
      a.doc_order.should be < pair[1].doc_order
    end
  end

  it "keeps add_next_sibling results ordered (fast path)" do
    doc = KXML.parse("<root><a/><b/></root>")
    a = doc.root.as(KXML::Element).elements[0]
    50.times { |i| a.add_next_sibling(doc.create_element("s#{i}")) }
    assert_increasing(element_orders(doc))
    names = doc.root.as(KXML::Element).elements.map(&.name)
    # Each insert lands directly after the anchor, so repeated inserts stack
    # in reverse (libxml2 xmlAddNextSibling semantics).
    names.first(51).should eq(["a"] + (0...50).to_a.reverse.map { |i| "s#{i}" })
  end

  it "renumbers lazily for add_prev_sibling and restores increasing order" do
    doc = KXML.parse("<root><a/><b/></root>")
    root = doc.root.as(KXML::Element)
    30.times { |i| root.children.first.add_prev_sibling(doc.create_element("p#{i}")) }
    doc.orders_dirty?.should be_true
    # Insertions keep appending before the first child in insertion order.
    names = root.elements.map(&.name)
    # Each insert lands directly before the first child, so repeated
    # inserts stack in reverse.
    names.should eq((0...30).to_a.reverse.map { |i| "p#{i}" } + ["a", "b"])
    # XPath evaluation is the order-dependent read: it must renumber first.
    nodes = KXML::XPath.evaluate_nodes("p19", doc.root.as(KXML::Element))
    nodes.size.should eq(1)
    doc.orders_dirty?.should be_false
    assert_increasing(element_orders(doc))
  end

  it "deduplicates and orders node-sets correctly while dirty" do
    doc = KXML.parse("<root><a/><b/></root>")
    root = doc.root.as(KXML::Element)
    10.times { root.children.first.add_prev_sibling(doc.create_element("p")) }
    nodes = KXML::XPath.evaluate_nodes("p | a | b", doc.root.as(KXML::Element))
    nodes.size.should eq(12)
  end

  it "mixes fast-path appends with dirty preinserts correctly" do
    doc = KXML.parse("<root><a/></root>")
    root = doc.root.as(KXML::Element)
    root.children.first.add_prev_sibling(doc.create_element("p1"))
    root.append_child(doc.create_element("z1"))
    root.children.first.add_prev_sibling(doc.create_element("p2"))
    root.append_child(doc.create_element("z2"))
    names = root.elements.map(&.name)
    names.should eq(["p2", "p1", "a", "z1", "z2"])
    assert_increasing(element_orders(doc))
    KXML::XPath.evaluate_nodes("z2", doc.root.as(KXML::Element)).size.should eq(1)
    KXML::XPath.evaluate_nodes("p1", doc.root.as(KXML::Element)).size.should eq(1)
  end

  it "keeps relative order after unlink without renumbering" do
    doc = KXML.parse("<root><a/><b/><c/></root>")
    root = doc.root.as(KXML::Element)
    b = root.elements[1]
    b.unlink
    doc.orders_dirty?.should be_false
    assert_increasing(element_orders(doc))
    names = root.elements.map(&.name)
    names.should eq(["a", "c"])
    # A fast-path append after the unlink must still sort after everything.
    root.append_child(doc.create_element("d"))
    assert_increasing(element_orders(doc))
    KXML::XPath.evaluate_nodes("d", doc.root.as(KXML::Element)).size.should eq(1)
  end

  it "orders text= replacements correctly" do
    doc = KXML.parse("<root><a>old</a></root>")
    a = doc.root.as(KXML::Element).elements[0]
    a.text = "new"
    a.text = "newer"
    assert_increasing(element_orders(doc))
    KXML::XPath.evaluate_nodes("/root/a[text() = 'newer']", doc.root.as(KXML::Element)).size.should eq(1)
  end
end
