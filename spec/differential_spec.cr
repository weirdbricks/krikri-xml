require "spec"
require "./spec_helper"
require "xml/dom/parser"
require "compress/zip"

# Differential testing: the same document parsed by KXML and by
# ysbaddaden/xml.cr (a libxml2-style SAX/DOM implementation developed
# independently) must yield structurally identical trees. xml.cr does not
# track namespaces, so the comparison covers element structure, attributes,
# text content, comments and processing instructions - everything both
# DOMs represent.

DIFF_REALWORLD_DIR = File.expand_path("../testdata/realworld", __DIR__)

private def kxml_walk(b : String::Builder, n : KXML::Node, depth : Int32) : Nil
  case n
  when KXML::Element
    b << depth << ":E:" << n.name
    n.attributes.each { |a| b << "|@" << a.name << "=" << a.value }
    b << "\n"
    n.children.each { |child| kxml_walk(b, child, depth + 1) }
  when KXML::Text
    b << depth << ":T:" << n.content << "\n" unless n.content.empty?
  when KXML::CData
    b << depth << ":C:" << n.content << "\n"
  when KXML::Comment
    # Top-level comments/PIs are excluded: the DOMs place prolog/epilog
    # misc nodes differently (xml.cr drops prolog ones and attaches
    # epilog ones to the root). Comments and PIs inside elements are
    # still compared.
    b << depth << ":M:" << n.content << "\n" unless depth == 0
  when KXML::ProcessingInstruction
    b << depth << ":P:" << n.target << ":" << n.content << "\n" unless depth == 0
  end
end

def kxml_signature(source : String) : String
  doc = KXML.parse(source)
  root = doc.root.not_nil!
  normalize_text(String.build { |b| kxml_walk(b, root, 0) })
end

# xml.cr keeps text nodes split at entity boundaries while KXML coalesces
# adjacent text (like libxml2); merge consecutive same-depth text entries
# so both signatures are comparable.
def normalize_text(sig : String) : String
  out = [] of String
  pending_depth : Int32? = nil
  pending_text = ""
  sig.each_line do |line|
    sep = line.index(":T:")
    if sep
      depth = line[0...sep].to_i
      if pending_depth == depth
        pending_text += line[(sep + 3)..]
      else
        if pd = pending_depth
          out << "#{pd}:T:#{pending_text}"
        end
        pending_depth = depth
        pending_text = line[(sep + 3)..]
      end
    else
      if pd = pending_depth
        out << "#{pd}:T:#{pending_text}"
        pending_depth = nil
      end
      out << line
    end
  end
  if pd = pending_depth
    out << "#{pd}:T:#{pending_text}"
  end
  out.join("\n") + "\n"
end

private def dom_walk(b : String::Builder, n : XML::DOM::Node, depth : Int32) : Nil
  case n
  when XML::DOM::Element
    b << depth << ":E:" << n.name
    n.attributes.each do |a|
      b << "|@" << a.name << "=" << a.value
    end
    b << "\n"
    n.each_child { |child| dom_walk(b, child, depth + 1) }
  when XML::DOM::Text
    b << depth << ":T:" << n.data << "\n" unless n.data.empty?
  when XML::DOM::CDataSection
    b << depth << ":C:" << n.data << "\n"
  when XML::DOM::Comment
    b << depth << ":M:" << n.data << "\n" unless depth == 0
  when XML::DOM::ProcessingInstruction
    b << depth << ":P:" << n.target << ":" << n.data << "\n" unless depth == 0
  end
end

def dom_signature(source : String) : String
  doc = XML::DOM.parse(IO::Memory.new(source))
  normalize_text(String.build { |b| dom_walk(b, doc.root, 0) })
end

private class Collector
  def initialize(@tests : Array(KXML::Element))
  end

  def collect(n : KXML::Node) : Nil
    return unless n.is_a?(KXML::Element) || n.is_a?(KXML::Document)
    n.children.each do |child|
      @tests << child if child.is_a?(KXML::Element) && child.name == "TEST"
      collect(child)
    end
  end
end

# Fixture documents exercising DTD internals, entity references, CDATA,
# namespaces, comments and PIs - areas the real-world files cover thinly.
FIXTURES = [
  %(<r><a x="1" y="2">t</a><b/></r>),
  %(<r>text<!--c-->more<?pi data?>tail</r>),
  %(<r><![CDATA[a<b]]>after</r>),
  %(<r a="&#65;&#x42;">&#67;</r>),
  %(<!DOCTYPE r [<!ENTITY e "expanded">]><r a="&e;">&e;&lt;tag&gt;</r>),
  %(<!DOCTYPE r [<!ENTITY e "v"><!ATTLIST r def CDATA "dflt">]><r>&e;</r>),
  %(<!DOCTYPE r [<!ATTLIST r n NMTOKENS "  a   b  ">]><r/>),
  %(<r xmlns="urn:d" xmlns:p="urn:p"><p:a p:x="1"><b/></p:a></r>),
  %(<r>&#38;amp;<![CDATA[&]]>&#x26;</r>),
  "  <r>\n" +
  "    <a>  spaced\n" +
  "    text  </a>\n" +
  "    <b></b>\n" +
  "  </r>\n",
  %(<?xml version="1.0" encoding="UTF-8"?><r x="&quot;q&quot;">'a'</r>),
]

describe "differential parsing (KXML vs XML::DOM)" do
  Dir.glob("#{DIFF_REALWORLD_DIR}/*").sort.each do |path|
    it "agrees with XML::DOM on #{File.basename(path)}" do
      source = File.read(path)
      kxml_signature(source).should eq(dom_signature(source))
    end
  end

  FIXTURES.each_with_index do |source, i|
    it "agrees with XML::DOM on fixture ##{i}" do
      kxml_signature(source).should eq(dom_signature(source))
    end
  end

  it "agrees on every well-formed conformance-suite case it can read" do
    # Drive the vendored W3C suite's "valid" cases through both parsers.
    Compress::Zip::File.open(File.expand_path("../testdata/xmlts20130923.zip", __DIR__)) do |zip|
      compared = 0
      disagreements = [] of String
      xml = zip["xmlconf/xmltest/xmltest.xml"].open(&.gets_to_end)
      catalog = KXML.parse(xml)
      tests = [] of KXML::Element
      collector = Collector.new(tests)
      collector.collect(catalog)
      tests.each do |test|
        next unless test["TYPE"] == "valid"
        uri = test["URI"]
        next if uri.nil?
        entry = zip["xmlconf/xmltest/#{uri}"]?
        next if entry.nil?
        content = entry.open(&.gets_to_end)
        next unless content.valid_encoding?
        begin
          k = kxml_signature(content)
        rescue KXML::Error
          next # KXML rejects; divergence is tracked by the conformance spec
        end
        begin
          d = dom_signature(content)
        rescue XML::DOM::Error
          next # xml.cr cannot handle it; not our signal
        end
        compared += 1
        disagreements << "#{test["ID"]} (#{uri})" if k != d
      end
      compared.should be > 100
      disagreements.should eq([] of String)
    end
  end
end
