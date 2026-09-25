require "spec"
require "./spec_helper"

# Property-style tests for the mutation API + serializer: apply sequences of
# deterministic pseudo-random DOM mutations, then require that the document
# stays internally consistent:
#
# - XPath document ordering is strictly increasing along every traversal,
#   so node ordering (which relies on doc_order) cannot silently break;
# - to_xml output re-parses to a structurally identical tree, and
#   serializing that re-parse is byte-identical (round-trip stability);
# - namespaces of moved nodes stay resolvable.

# Deterministic small PRNG so failures reproduce.
class LCG
  @state : UInt64

  def initialize(seed : UInt64)
    @state = seed &+ 0x9E3779B97F4A7C15u64
  end

  def next_u64 : UInt64
    @state = (@state &* 6364136223846793005) &+ 1442695040888963407
    @state
  end

  def below(n : Int32) : Int32
    (next_u64 % n.to_u64).to_i
  end
end

def check_orders(node : KXML::Node, prev : Int32 = -1) : Int32
  order = prev
  if node.is_a?(KXML::Element)
    raise "doc_order not increasing at #{node.name}" unless node.doc_order > order
    order = node.doc_order
  end
  if node.is_a?(KXML::Element) || node.is_a?(KXML::Document)
    node.children.each { |child| order = check_orders(child, order) }
  end
  order
end

def snapshot(node : KXML::Node) : String
  String.build do |b|
    b << node.class.to_s.split("::").last
    b << "(#{node.name})" if node.is_a?(KXML::Element)
    b << "=#{node.content}" if node.is_a?(KXML::Text)
    if node.is_a?(KXML::Element)
      node.attributes.each { |a| b << " @#{a.name}=#{a.value}" }
    end
  end
end

def structural_signature(node : KXML::Node) : String
  String.build do |b|
    b << snapshot(node)
    if node.responds_to?(:children)
      node.children.each { |child| b << "|" << structural_signature(child) }
    end
  end
end

# All elements of the tree.
def all_elements(node : KXML::Node, acc : Array(KXML::Element) = [] of KXML::Element) : Array(KXML::Element)
  acc << node if node.is_a?(KXML::Element)
  node.children.each { |child| all_elements(child, acc) if child.is_a?(KXML::Element) || child.is_a?(KXML::Document) }
  acc
end

BASE = KXML.parse(%(<r xmlns:p="urn:p" n="0"><p:a x="1">t1</p:a><b><c/></b><d>tail</d></r>))

MUTATION_OPS = 40
TREES        = 25

describe "mutation round-trip" do
  it "keeps doc_order increasing through random mutations" do
    TREES.times do |i|
      doc = KXML.parse(BASE.to_xml)
      rng = LCG.new(0xDEADBEEFu64 + i.to_u64)
      MUTATION_OPS.times do |op|
        elems = all_elements(doc)
        target = elems[rng.below(elems.size)]
        case rng.below(6)
        when 0
          target.append_child(KXML::Text.new("x#{op}"))
        when 1
          target.append_child(doc.create_element("new#{op}"))
        when 2
          begin
            target.add_next_sibling(doc.create_element("sib#{op}"))
          rescue KXML::Error
            # parentless target: acceptable
          end
        when 3
          target.set_attribute("k#{op}", "v#{op}")
        when 4
          attrs = target.attributes.map &.name
          target.delete_attribute(attrs[rng.below(attrs.size)]) unless attrs.empty?
        when 5
          target.text = "t#{op}" if target.elements.empty?
        end
        # Insertions before existing nodes renumber lazily (placeholder
        # orders + dirty flag); the invariant under test is that a renumber
        # pass always restores strictly increasing document order.
        doc.renumber
        check_orders(doc)
      end
    end
  end

  it "round-trips mutated trees through to_xml and re-parse" do
    TREES.times do |i|
      doc = KXML.parse(BASE.to_xml)
      rng = LCG.new(0xC0FFEEu64 + i.to_u64)
      MUTATION_OPS.times do |op|
        elems = all_elements(doc)
        target = elems[rng.below(elems.size)]
        case rng.below(4)
        when 0
          target.append_child(doc.create_element("n#{op}", context: target))
        when 1
          target.set_attribute("a#{op}", "v#{op}")
        when 2
          target.append_child(KXML::Text.new("s#{op}"))
        when 3
          target.text = "only#{op}"
        end
      end
      xml1 = doc.to_xml
      reparsed = KXML.parse(xml1)
      structural_signature(reparsed).should eq(structural_signature(doc))
      xml2 = reparsed.to_xml
      xml2.should eq(xml1)
    end
  end

  it "keeps namespaces resolvable after moving nodes" do
    doc = KXML.parse(BASE.to_xml)
    root = doc.root.not_nil!
    p_item = root.elements[0] # p:a in urn:p
    # Move a namespaced element under another parent: the binding travels
    # only if declared on an ancestor, so re-parse must keep the URI.
    b = root.elements[1]
    b.append_child(p_item)
    xml = doc.to_xml
    reparsed_root = KXML.parse(xml).root.not_nil!
    moved = reparsed_root.elements.flat_map(&.elements).find { |found| found.name == "p:a" }
    moved = moved.not_nil!
    KXML::XPath.evaluate("namespace-uri(.)", moved).should eq("urn:p")
  end

  it "unlinked nodes disappear from serialization and XPath" do
    doc = KXML.parse(BASE.to_xml)
    root = doc.root.not_nil!
    victim = root.elements[1] # <b>
    victim.unlink
    doc.to_xml.should_not contain("<b")
    KXML::XPath.evaluate_nodes("//b", root).size.should eq(0)
    victim.parent_node.should be_nil
  end
end
