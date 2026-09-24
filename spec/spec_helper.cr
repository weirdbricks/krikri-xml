require "spec"
require "../src/krikri-xml"

def expect_error(source : String, message : String? = nil) : KXML::Error
  ex = expect_raises KXML::Error do
    KXML.parse(source)
  end
  ex.message.not_nil!.should contain(message) if message
  ex
end
