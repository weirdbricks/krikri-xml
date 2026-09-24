# Benchmark comparing krikri-xml (KXML) against ysbaddaden/xml.cr (XML::DOM).
#
# Run with:
#   crystal run bench/bench.cr --release
#
# xml.cr is a SAX push-parser with a DOM layer on top, built on libxml2-style
# event flow but implemented in pure Crystal. It has no XPath and no
# serializer, so those comparisons are KXML-only and marked as such.

require "io/memory"
require "../src/krikri-xml"
require "xml/dom/parser"

# ---------------------------------------------------------------- fixtures

# Generates deterministic XML. depth controls nesting depth, width the
# number of children per element, attrs the number of attributes per element.
def generate_xml(depth : Int32, width : Int32, attrs : Int32) : String
  io = IO::Memory.new
  io << %(<?xml version="1.0" encoding="UTF-8"?>\n)
  io << %(<root xmlns="urn:bench" version="1.0">\n)

  width.times do |w_idx|
    io << "<branch>"
    append_subtree(io, 1, depth, w_idx, width, attrs)
    io << "</branch>\n"
  end
  io << "</root>\n"
  io.to_s
end

def append_subtree(io : IO, level : Int32, depth : Int32, index : Int32, width : Int32, attrs : Int32) : Nil
  name = "level#{level}"
  io << "<" << name
  attrs.times do |a|
    io << " attr#{a}=\"value-#{index}-#{a}\""
  end
  io << ">"
  io << "text #{index} &amp; more \u00E9\u00FC"
  if level < depth
    width.times do |w_idx|
      append_subtree(io, level + 1, depth, w_idx, width, attrs)
    end
  end
  io << "</" << name << ">\n"
end

FIXTURES = {
  "small (depth 4, width 3)"   => generate_xml(4, 3, 2),
  "medium (depth 4, width 6)"  => generate_xml(4, 6, 2),
  "large (depth 4, width 12)"  => generate_xml(4, 12, 3),
  "wide (depth 1, width 3000)" => generate_xml(1, 3000, 2),
  "deep (depth 300, width 1)"  => generate_xml(300, 1, 1),
  "attrs (depth 1, w500, a20)" => generate_xml(1, 500, 20),
}

# Consumed at the end so traversal work is not optimized away.
SINK = Atomic(Int64).new(0)

# ---------------------------------------------------------------- harness

struct Measurement
  getter seconds : Float64
  getter iterations : Int32

  def initialize(@seconds, @iterations)
  end

  def per_op_ms : Float64
    seconds * 1000.0 / iterations
  end

  def mb_per_s(bytes : Int64) : Float64
    (bytes * iterations) / seconds / (1024.0 * 1024.0)
  end
end

# Times `iterations` runs of the block; returns the best (fastest) run so
# noise, GC pauses and CPU frequency drift inflate the median but not the min.
def measure(iterations : Int32, &block : -> Nil) : Measurement
  GC.collect
  best = Float64::INFINITY
  iterations.times do
    start = Time.instant
    block.call
    elapsed = Time.instant - start
    best = elapsed.total_seconds if elapsed.total_seconds < best
  end
  Measurement.new(best, iterations)
end

# ---------------------------------------------------------------- walkers

# counts[0] = elements, counts[1] = attributes, counts[2] = text bytes.
# Only elements are counted as nodes: xml.cr's SAX layer emits character
# data per callback (splitting text around entity references) while KXML
# merges contiguous text, so raw text-node counts legitimately differ.
def kxml_walk(node : KXML::Node, counts : Array(Int32)) : Nil
  case node
  when KXML::Document
    node.children.each { |child| kxml_walk(child, counts) }
  when KXML::Element
    counts[0] += 1
    counts[1] += node.attributes.size
    node.children.each { |child| kxml_walk(child, counts) }
  when KXML::Text
    counts[2] += node.content.size
  end
end

def xmldom_walk(node : XML::DOM::Node, counts : Array(Int32)) : Nil
  case node
  when XML::DOM::Document
    node.each_child { |child| xmldom_walk(child, counts) }
  when XML::DOM::Element
    counts[0] += 1
    counts[1] += node.attributes.size
    node.each_child { |child| xmldom_walk(child, counts) }
  when XML::DOM::Text
    counts[2] += node.data.size
  end
end

# ---------------------------------------------------------------- benchmark

def bench_parse(name : String, xml : String, iterations : Int32)
  bytes = xml.bytesize.to_i64

  k = measure(iterations) { KXML.parse(xml) }
  x = measure(iterations) { XML::DOM.parse(IO::Memory.new(xml)) }

  # Cross-check: both DOMs must see the same tree shape.
  kdoc = KXML.parse(xml)
  kcounts = [0, 0, 0]
  kxml_walk(kdoc.root.as(KXML::Element), kcounts)
  xdoc = XML::DOM.parse(IO::Memory.new(xml))
  xcounts = [0, 0, 0]
  xmldom_walk(xdoc.root, xcounts)
  unless kcounts == xcounts
    raise "walk mismatch on #{name}: KXML #{kcounts} vs xml.cr #{xcounts}"
  end

  {name, bytes, k, x}
end

def bench_traverse(name : String, xml : String, iterations : Int32)
  kdoc = KXML.parse(xml)
  xdoc = XML::DOM.parse(IO::Memory.new(xml))

  k = measure(iterations) do
    counts = [0, 0, 0]
    kxml_walk(kdoc.root.as(KXML::Element), counts)
    SINK.add(counts[0] + counts[1] + counts[2]).to_i64
  end
  x = measure(iterations) do
    counts = [0, 0, 0]
    xmldom_walk(xdoc.root, counts)
    SINK.add(counts[0] + counts[1] + counts[2]).to_i64
  end
  {name, k, x}
end

def bench_serialize(iterations : Int32)
  xml = FIXTURES["medium (depth 4, width 6)"]
  kdoc = KXML.parse(xml)
  k = measure(iterations) { kdoc.to_xml }
  k
end

def bench_xpath(iterations : Int32)
  xml = FIXTURES["medium (depth 4, width 6)"]
  doc = KXML.parse(xml)
  root = doc.root.as(KXML::Element)
  k = measure(iterations) do
    KXML::XPath.evaluate_nodes("branch/level1/level2/level3[@attr0='value-2-0']", root)
  end
  k
end

# ---------------------------------------------------------------- report

puts "Crystal #{Crystal::VERSION}"
puts "krikri-xml (KXML) vs ysbaddaden/xml.cr (XML::DOM)"
puts

header = "%-32s %10s %12s %12s %10s" % ["parse", "bytes", "kxml ms/op", "xml.cr ms/op", "kxml/x"]
puts header
puts "-" * header.size
FIXTURES.each do |name, xml|
  # Iterations scaled so each fixture measures in a useful range.
  iterations = xml.bytesize > 500_000 ? 5 : (xml.bytesize > 50_000 ? 20 : 100)
  _, bytes, k, x = bench_parse(name, xml, iterations)
  ratio = x.per_op_ms / k.per_op_ms
  puts "%-32s %10s %12.3f %12.3f %9.2fx" % [name, bytes, k.per_op_ms, x.per_op_ms, ratio]
end
puts

header = "%-32s %12s %12s %10s" % ["traverse", "nodes", "kxml ms/op", "xml.cr ms/op", "kxml/x"]
puts header
puts "-" * header.size
FIXTURES.each do |name, xml|
  iterations = xml.bytesize > 500_000 ? 5 : (xml.bytesize > 50_000 ? 20 : 100)
  _, k, x = bench_traverse(name, xml, iterations)
  ratio = x.per_op_ms / k.per_op_ms
  kdoc = KXML.parse(xml)
  counts = [0, 0, 0]
  kxml_walk(kdoc.root.as(KXML::Element), counts)
  puts "%-32s %12s %12.4f %12.4f %9.2fx" % [name, counts[0], k.per_op_ms, x.per_op_ms, ratio]
end
puts

k = bench_serialize(20)
puts "%-32s %12s %12.3f" % ["serialize to_xml (KXML only)", "n/a", k.per_op_ms]
k = bench_xpath(50)
puts "%-32s %12s %12.3f" % ["XPath step (KXML only)", "n/a", k.per_op_ms]
puts
puts "(kxml/x > 1 means KXML is faster)"
puts "(traversal sink: #{SINK.get})"
