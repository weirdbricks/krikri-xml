require "spec"
require "./spec_helper"

# Boundary tests for the parser's resource limits: each configurable
# limit must reject documents one step past it with a clean KXML::Error,
# and accept documents exactly at it. The fuzz spec checks over-limit
# rejection generally; these pin the exact boundary.

def entity_chain(depth : Int32, leaf : String = "x") : String
  decls = String::Builder.new
  (depth - 1).times do |i|
    decls << "<!ENTITY e#{i} \"&e#{i + 1};\">"
  end
  decls << "<!ENTITY e#{depth - 1} \"#{leaf}\">"
  d = decls.to_s
  "<!DOCTYPE r [#{d}]><r>&e0;</r>"
end

describe "resource limits" do
  it "accepts entity nesting exactly at MAX_ENTITY_DEPTH" do
    doc = KXML.parse(entity_chain(KXML::Parser::MAX_ENTITY_DEPTH))
    doc.root.not_nil!.text_content.should eq("x")
  end

  it "rejects entity nesting one past MAX_ENTITY_DEPTH" do
    expect_error(entity_chain(KXML::Parser::MAX_ENTITY_DEPTH + 1))
  end

  it "accepts element nesting exactly at MAX_ELEMENT_DEPTH" do
    n = KXML::Parser::MAX_ELEMENT_DEPTH
    doc = KXML.parse(("<d>" * n) + ("</d>" * n))
    # walk to the innermost element
    e = doc.root.not_nil!
    (n - 1).times { e = e.elements[0] }
    e.name.should eq("d")
  end

  it "rejects element nesting one past MAX_ELEMENT_DEPTH" do
    n = KXML::Parser::MAX_ELEMENT_DEPTH + 1
    expect_error(("<d>" * n) + ("</d>" * n))
  end

  it "rejects entity expansion past MAX_EXPANDED_BYTES" do
    # One entity whose replacement text alone exceeds the limit.
    leaf = "x" * (KXML::Parser::MAX_EXPANDED_BYTES + 1)
    expect_error(%(<!DOCTYPE r [<!ENTITY big "#{leaf}">]><r>&big;</r>))
  end

  it "tracks cumulative expansion across entities past MAX_EXPANDED_BYTES" do
    # Each entity is small, but referencing them repeatedly accumulates
    # past the expansion budget.
    small = "x" * 1000
    decls = String::Builder.new
    64.times { |i| decls << "<!ENTITY s#{i} \"#{small}\">" }
    refs = (64.times.map { |i| "&s#{i};" }).join
    d = decls.to_s
    r = refs.to_s
    expect_error(%(<!DOCTYPE r [#{d}]><r>#{r * 160}</r>))
  end

  it "accepts expansion just under MAX_EXPANDED_BYTES" do
    total = KXML::Parser::MAX_EXPANDED_BYTES
    chunk = "x" * 1000
    count = (total // 1000) - 1
    decls = String::Builder.new
    count.times { |i| decls << "<!ENTITY s#{i} \"#{chunk}\">" }
    refs = String::Builder.new
    count.times { |i| refs << "&s#{i};" }
    d = decls.to_s
    r = refs.to_s
    doc = KXML.parse(%(<!DOCTYPE r [#{d}]><r>#{r}</r>))
    doc.root.not_nil!.text_content.bytesize.should eq(chunk.bytesize * count)
  end

  it "reports positions on limit violations, not internal errors" do
    ex = expect_error("<d>" * (KXML::Parser::MAX_ELEMENT_DEPTH + 1) + "</d>" * (KXML::Parser::MAX_ELEMENT_DEPTH + 1))
    ex.message.not_nil!.should contain("depth")
    ex.line.should be > 0
  end
end
