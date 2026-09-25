require "spec"
require "./spec_helper"

# Fuzzing: the parser's core promise is that *any* input either parses or
# raises KXML::Error - never a crash, hang, or foreign exception class.
# The mutations and seeds are deterministic so failures are reproducible.

private def fuzz_parse(input : String, label : String) : Nil
  KXML.parse(input)
rescue e : KXML::Error
  # Expected: strict rejection. All good.
rescue e
  raise "fuzz crash on #{label}: #{e.class}: #{e.message}\n#{input.inspect}"
end

# Byte mutations of well-formed documents: substitutions, insertions,
# deletions, truncations, duplicated spans.
private def mutate(source : String, rng : Random) : String
  bytes = source.bytes
  case rng.rand(6)
  when 0
    i = rng.rand(bytes.size + 1)
    bytes.insert(i, rand_char(rng))
  when 1
    if bytes.size > 0
      i = rng.rand(bytes.size)
      bytes[i] = rand_char(rng)
    end
  when 2
    if bytes.size > 0
      bytes.delete_at(rng.rand(bytes.size))
    end
  when 3
    return source[0, rng.rand(source.size + 1)]
  when 4
    if bytes.size > 1
      a = rng.rand(bytes.size)
      b = rng.rand(bytes.size)
      bytes[a], bytes[b] = bytes[b], bytes[a]
    end
  when 5
    if bytes.size > 0
      a = rng.rand(bytes.size)
      b = rng.rand(bytes.size)
      span = bytes[Math.min(a, b)..Math.max(a, b)]
      i = rng.rand(bytes.size + 1)
      bytes[i, 0] = span
    end
  end
  String.new(Slice.new(bytes.to_unsafe, bytes.size))
end

private def rand_char(rng : Random) : UInt8
  table = "<>&\"'/=!?- \t\n\r\x00#{'a'.ord}#{'Z'.ord}#{'0'.ord}"
  table.bytes[rng.rand(table.size)]
end

SEEDS    = ["xml", "xpath", "entities", "mutation", "namespaces", "doctype"]
MUTANTS  = 300

describe "fuzzing" do
  it "raises KXML::Error (or parses) on mutated well-formed documents" do
    SEEDS.each do |seed|
      source = %(<?xml version="1.0"?><#{seed} xmlns:a="urn:x"><a:child a:attr="1">te<!--c-->xt<![CDATA[cd]]><?pi p?></a:child></#{seed}>)
      rng = Random.new(seed.hash & 0xFFFF)
      MUTANTS.times do |i|
        fuzz_parse(mutate(source, rng), "#{seed}##{i}")
      end
    end
  end

  it "raises KXML::Error (or parses) on adversarial inputs" do
    adversarial = [
      "",
      "<",
      "<>",
      "<?",
      "<?xml",
      "<?xml version",
      "<?xml version=\"1.0\"?>",
      "<!-- unterminated",
      "<![CDATA[ unterminated",
      "<!DOCTYPE",
      "<!DOCTYPE d [<!ENTITY e SYSTEM \"x\">]><d>&e;</d>",
      "<!DOCTYPE d [<!ENTITY % e SYSTEM \"x\">%e;]><d/>",
      "<d>&#x110000;</d>",
      "<d>&#0;</d>",
      "<d>&#xD800;</d>",
      "<d>&#xFFFE;</d>",
      "<d>&undeclared;</d>",
      "<d a='&undefined;'>x</d>",
      "<d>&amp;&lt;&gt;&apos;&quot;</d>",
      "<d>&lt</d>",
      "<d><a></d>",
      "<d><a><b></a></b></d>",
      "<a:b xmlns:c='urn:x'>x</a:b>",
      "<d xmlns:a='urn:x'><a:b/></d>",
      "<d xmlns='urn:x'><d xmlns=''/></d>",
      "<d/>trailing<",
      "<d></d></d>",
      "<?xml version=\"1.1\"?><d/>",
      "<3d/>",
      "<d/>",
      "<d />",
      "</d>",
      "<d>&</d>",
      "<d>]]></d>",
      "<d><![CDATA[]]]></d>",
      "<d a='1' a='2'/>",
      "<d a='1'/>",
      "<d\n/>",
      "﻿<d/>",
      "<d>\u{1}</d>",
      "<d>\u{D}</d>",
      String.new(Bytes[0x3C, 0xD8, 0x3E]),
    ]
    adversarial.each_with_index do |input, i|
      fuzz_parse(input, "adversarial##{i}")
    end
  end

  it "stays inside the configured limits instead of crashing" do
    fuzz_parse("<d>" + ("&amp;" * 500_000) + "</d>", "expansion-size")
    # MAX_ELEMENT_DEPTH is 2_048 and must be reachable *before* the call
    # stack overflows: over-limit nesting raises KXML::Error, a document at
    # the limit parses.
    fuzz_parse("<d>" * 20_000, "depth-over-limit")
    KXML.parse(("<d>" * KXML::Parser::MAX_ELEMENT_DEPTH) + ("</d>" * KXML::Parser::MAX_ELEMENT_DEPTH))
  end

  it "rejects runaway entity expansion instead of crashing" do
    laugher = String::Builder.new
    laugher << "<!DOCTYPE d [\n"
    8.times { |i| laugher << "<!ENTITY l#{i} \"&#38;l#{i + 1};\">\n" }
    laugher << "<!ENTITY l9 \"" << ("x" * 1000) << "\">\n]><d>&l0;</d>"
    fuzz_parse(laugher.to_s, "billion-laughs")
  end
end
