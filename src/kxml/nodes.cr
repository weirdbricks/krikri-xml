require "set"

module KXML
  XML_NAMESPACE_URI   = "http://www.w3.org/XML/1998/namespace"
  XMLNS_NAMESPACE_URI = "http://www.w3.org/2000/xmlns/"

  class Error < Exception
    getter line : Int32
    getter column : Int32
    getter context : String

    def initialize(message : String, @line : Int32, @column : Int32, @context : String = "document")
      super("#{message} (#{context}, line #{@line}, column #{@column})")
    end
  end

  class Attribute
    getter name : String
    getter prefix : String?
    getter local_name : String
    getter namespace_uri : String?
    getter value : String
    getter specified : Bool

    def initialize(@name : String, @prefix : String?, @local_name : String,
                   @namespace_uri : String?, @value : String, @specified : Bool)
    end
  end

  abstract class Node
    property parent_node : Node?

    def document : Document?
      node : Node? = self
      while node = node.parent_node
        return node if node.is_a?(Document)
      end
      nil
    end

    def parent_element : Element?
      p = parent_node
      p.is_a?(Element) ? p : nil
    end

    abstract def to_xml(io : IO) : Nil

    def to_xml : String
      String.build { |io| to_xml(io) }
    end
  end

  class Document < Node
    property root : Element?
    property doctype : DocumentType?
    getter misc_before = [] of Node
    getter misc_after = [] of Node

    def children : Array(Node)
      nodes = [] of Node
      nodes.concat(misc_before)
      if r = @root
        nodes << r
      end
      nodes.concat(misc_after)
      nodes
    end

    def to_xml(io : IO) : Nil
      misc_before.each &.to_xml(io)
      if d = doctype
        d.to_xml(io)
      end
      if r = root
        r.to_xml(io)
      end
      misc_after.each &.to_xml(io)
    end
  end

  class Element < Node
    getter name : String
    getter prefix : String?
    getter local_name : String
    getter namespace_uri : String?
    getter attributes : Array(Attribute)
    getter children = [] of Node

    def initialize(@name : String, @prefix : String?, @local_name : String,
                   @namespace_uri : String?, @attributes : Array(Attribute))
    end

    def attribute(name : String) : Attribute?
      attributes.find { |a| a.name == name }
    end

    def [](name : String) : String?
      attribute(name).try &.value
    end

    def elements : Array(Element)
      children.select(Element)
    end

    def text_content : String
      String.build do |b|
        append_text(self, b)
      end
    end

    private def append_text(node : Node, b : String::Builder) : Nil
      node.children.each do |child|
        case child
        when Text, CData
          b << child.content
        when Element
          append_text(child, b)
        end
      end
    end

    def to_xml(io : IO) : Nil
      io << '<' << name
      attributes.each do |a|
        io << ' ' << a.name << "=\"" << KXML.escape_attribute(a.value) << '"'
      end
      if children.empty?
        io << "/>"
      else
        io << '>'
        children.each &.to_xml(io)
        io << "</" << name << '>'
      end
    end
  end

  class Text < Node
    property content : String

    def initialize(@content : String)
    end

    def to_xml(io : IO) : Nil
      io << KXML.escape_text(content)
    end
  end

  class CData < Node
    getter content : String

    def initialize(@content : String)
    end

    def to_xml(io : IO) : Nil
      io << "<![CDATA[" << content << "]]>"
    end
  end

  class Comment < Node
    getter content : String

    def initialize(@content : String)
    end

    def to_xml(io : IO) : Nil
      io << "<!--" << content << "-->"
    end
  end

  class ProcessingInstruction < Node
    getter target : String
    getter content : String

    def initialize(@target : String, @content : String)
    end

    def to_xml(io : IO) : Nil
      io << "<?" << target
      unless content.empty?
        io << ' ' << content
      end
      io << "?>"
    end
  end

  class DocumentType < Node
    getter name : String
    getter public_id : String?
    getter system_id : String?

    def initialize(@name : String, @public_id : String?, @system_id : String?)
    end

    def to_xml(io : IO) : Nil
      io << "<!DOCTYPE " << name
      if pid = public_id
        io << " PUBLIC \"" << pid << '"'
        io << " \"" << (system_id || "") << '"'
      elsif sid = system_id
        io << " SYSTEM \"" << sid << '"'
      end
      io << '>'
    end
  end

  def self.escape_text(s : String) : String
    s.gsub('&', "&amp;").gsub('<', "&lt;").gsub('>', "&gt;")
  end

  def self.escape_attribute(s : String) : String
    s.gsub('&', "&amp;").gsub('<', "&lt;").gsub('"', "&quot;")
      .gsub('\n', "&#10;").gsub('\t', "&#9;")
  end
end
