# Focused benchmark for the DEEPSEEK.md optimizations.
#
# Run with:
#   crystal run bench/opt_bench.cr --release
#
# Measures the areas the optimizations touch: serialization, parse,
# mutation-order allocation, namespaced XPath steps and comparison-heavy
# predicates. Purely KXML-side, no cross-library comparison.

require "io/memory"
require "../src/krikri-xml"

SINK = Atomic(Int64).new(0)

def measure(iterations : Int32, &block : -> Nil) : Float64
  GC.collect
  best = Float64::INFINITY
  iterations.times do
    start = Time.instant
    block.call
    elapsed = Time.instant - start
    best = elapsed.total_seconds if elapsed.total_seconds < best
  end
  best
end

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

NS_XML = begin
  io = IO::Memory.new
  io << %(<?xml version="1.0"?>\n<root xmlns:p="urn:t" xmlns:q="urn:u">)
  2000.times { |i| io << %(<p:item id="#{i}" q:alt="a#{i}"><q:leaf>#{i}</q:leaf></p:item>) }
  io << "</root>"
  io.to_s
end

MUT_XML = nil # mutation bench builds its own document

report = [] of String

# --- serialize -------------------------------------------------------------
xml = generate_xml(4, 6, 2)
doc = KXML.parse(xml)
t = measure(300) { doc.to_xml }
report << "serialize medium      : %.4f ms/op" % (t * 1000)

# --- parse -----------------------------------------------------------------
t = measure(40) { KXML.parse(xml) }
report << "parse medium          : %.4f ms/op" % (t * 1000)

# --- mutation: build a wide document via append_child -----------------------
t = measure(10) do
  d = KXML.parse("<root/>")
  root = d.root.as(KXML::Element)
  5000.times do |i|
    e = d.create_element("item")
    e.set_attribute("id", i.to_s)
    root.append_child(e)
    SINK.add(1)
  end
end
report << "mutate 5000 appends   : %.4f ms/op" % (t * 1000)

# --- mutation: insert before the first child (worst case) -------------------
t = measure(5) do
  d = KXML.parse(generate_xml(1, 2000, 1))
  root = d.root.as(KXML::Element)
  400.times do
    n = d.create_element("new")
    root.children.first.add_prev_sibling(n)
    SINK.add(1)
  end
end
report << "mutate 400 preinserts : %.4f ms/op" % (t * 1000)

# --- namespaced XPath step --------------------------------------------------
nsdoc = KXML.parse(NS_XML)
root = nsdoc.root.as(KXML::Element)
t = measure(20) do
  nodes = KXML::XPath.evaluate_nodes("/root/p:item[@id > '1990']", root)
  SINK.add(nodes.size)
end
report << "xpath //p:item pred   : %.4f ms/op" % (t * 1000)

# --- comparison-heavy predicate --------------------------------------------
t = measure(20) do
  nodes = KXML::XPath.evaluate_nodes("//q:leaf[text() = '1999']", root)
  SINK.add(nodes.size)
end
report << "xpath text() = '1999' : %.4f ms/op" % (t * 1000)

puts "Crystal #{Crystal::VERSION}"
report.each { |line| puts line }
puts "(sink: #{SINK.get})"
