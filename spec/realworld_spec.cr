require "spec"
require "./spec_helper"

# Real-world document corpus: well-known XML files from production
# software and live feeds, vendored under testdata/realworld/. These
# exercise accumulated parser state over large, messy, real documents -
# far beyond the conformance suite's tiny synthetic files. Each file must
# parse, survive a serialization round-trip byte-stably, and answer XPath
# queries consistently with its own structure.

REALWORLD_DIR = File.expand_path("../testdata/realworld", __DIR__)

# file => {root element name, expected minimum element count}
DOCUMENTS = [
  {"maven-pom.xml", "project", 200},
  {"rss-nasa.xml", "rss", 100},
  {"atom-microsoft.xml", "feed", 50},
  {"github.svg", "svg", 3},
  {"docbook.xsl", "xsl:stylesheet", 250},
  {"ant-build.xml", "project", 500},
  {"android-layout.xml", "FrameLayout", 2},
  {"programming.opml", "opml", 40},
]

describe "real-world corpus" do
  DOCUMENTS.each do |file, root_name, min_elements|
    it "parses and round-trips #{file}" do
      source = File.read(File.join(REALWORLD_DIR, file))
      doc = KXML.parse(source)
      doc.root.not_nil!.name.should eq(root_name)

      # Count elements via XPath and via traversal: must agree.
      by_xpath = KXML::XPath.evaluate("count(//*)", doc.root.not_nil!)
      walked = 0
      stack = [doc.root.not_nil!.as(KXML::Node)]
      until stack.empty?
        n = stack.pop
        walked += 1 if n.is_a?(KXML::Element)
        n.children.each { |child| stack << child if child.is_a?(KXML::Element) } if n.is_a?(KXML::Element)
      end
      by_xpath.should eq(walked.to_f)
      walked.should be >= min_elements

      # Round-trip: re-parsing the serialization yields a byte-identical
      # serialization (the parser must not be lossy on well-formed input).
      xml1 = doc.to_xml
      xml2 = KXML.parse(xml1).to_xml
      xml2.should eq(xml1)

      # The re-parsed tree must have the same number of elements.
      KXML::XPath.evaluate("count(//*)", KXML.parse(xml1).root.not_nil!).should eq(by_xpath)
    end

    it "gives consistent XPath results on #{file}" do
      doc = KXML.parse(File.read(File.join(REALWORLD_DIR, file)))
      root = doc.root.not_nil!
      # local-name() of every element via XPath must match traversal.
      nodes = KXML::XPath.evaluate_nodes("//*", root)
      nodes.each do |node|
        KXML::XPath.evaluate("name(.)", node).should eq(node.as(KXML::Element).name)
      end
      # Document order must be strictly increasing along the node-set.
      orders = nodes.map &.doc_order
      orders.should eq(orders.sort)
      orders.uniq.size.should eq(orders.size)
    end
  end

  it "rejects the deliberately-malformed real-world file with a position" do
    source = File.read(File.join(REALWORLD_DIR, "maven-pom.xml"))
    truncated = source[0, source.size // 2]
    ex = expect_error(truncated)
    ex.line.should be > 0
  end
end
