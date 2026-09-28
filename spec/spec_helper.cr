require "minitest/autorun"
require "../src/krikri-xml"

# Shared spec helpers. minitest assertion methods live on test classes,
# so helpers that assert must be instance methods of the test classes
# rather than top-level defs.
module SpecHelpers
  def expect_error(source : String, message : String? = nil) : KXML::Error
    ex = assert_raises KXML::Error do
      KXML.parse(source)
    end
    assert ex.message.not_nil!.includes?(message) if message
    ex
  end
end

class Minitest::Spec
  include SpecHelpers
end
