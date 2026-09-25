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
    property doc_order : Int32 = 0
    getter name : String
    getter prefix : String?
    getter local_name : String
    getter namespace_uri : String?
    getter value : String
    getter? specified : Bool

    def initialize(@name : String, @prefix : String?, @local_name : String,
                   @namespace_uri : String?, @value : String, @specified : Bool)
    end
  end

  abstract class Node
    property parent_node : Node?
    # Document order, assigned by the parser (creation order). 0 for the
    # document node itself.
    property doc_order : Int32 = 0

    def document : Document?
      node : Node = self
      while p = node.parent_node
        return p if p.is_a?(Document)
        node = p
      end
      nil
    end

    def parent_element : Element?
      p = parent_node
      p.is_a?(Element) ? p : nil
    end

    abstract def to_xml(io : IO) : Nil

    def to_xml(io : IO, pretty : Bool, depth : Int32, indent_size : Int32) : Nil
      to_xml(io)
    end

    def to_xml : String
      String.build { |io| to_xml(io) }
    end

    # Removes this node from its parent's child list (mutation API for
    # consumers that edit documents in place; a no-op without a parent).
    def unlink : Nil
      if parent = parent_node
        case parent
        when Element
          parent.children.delete(self)
        when Document
          if parent.root.same?(self)
            parent.root = nil
          else
            parent.misc_before.delete(self)
            parent.misc_after.delete(self)
          end
        end
        self.parent_node = nil
      end
    end

    # Moves *node* (removing it from any existing parent first) to just
    # after this node among the parent's children - libxml2's
    # xmlAddNextSibling move semantics.
    def add_next_sibling(node : Node) : Node
      parent = parent_node
      raise Error.new("cannot add a sibling to a parentless node", 0, 0) unless parent.is_a?(Element)
      node.unlink if node.parent_node
      list = parent.children
      index = list.index(&.same?(self)) || list.size - 1
      doc = parent.document
      if doc
        prev_last = doc.deepest_last
        pred = doc.deepest_last_of(self)
      end
      node.parent_node = parent
      list.insert(index + 1, node)
      if doc
        if prev_last && pred
          doc.allocate_order_after(node, pred, prev_last)
        else
          doc.allocate_order(node)
        end
      end
      node
    end

    # Moves *node* to just before this node (xmlAddPrevSibling semantics).
    def add_prev_sibling(node : Node) : Node
      parent = parent_node
      raise Error.new("cannot add a sibling to a parentless node", 0, 0) unless parent.is_a?(Element)
      node.unlink if node.parent_node
      list = parent.children
      index = list.index(&.same?(self)) || 0
      node.parent_node = parent
      list.insert(index, node)
      parent.document.try(&.allocate_order(node))
      node
    end
  end

  class Document < Node
    property root : Element?
    property doctype : DocumentType?
    getter misc_before = [] of Node
    getter misc_after = [] of Node

    # Attribute names declared `ID` in the internal DTD subset
    # (population is best-effort: only ATTLIST declarations seen during
    # the parse register here). Lets XPath's id() resolve tokens.
    getter id_attribute_names = Set(String).new

    # Creates an element for *name* (a Clark-notation `{uri}local` or a
    # plain/qualified name). When a namespace URI is involved and no
    # in-scope binding exists on *context* (or its ancestors), the
    # binding is declared on the new element itself using *prefix_hint*
    # (or a generated `nsN`) - mirroring libxml2's
    # xmlSearchNsByHref/xmlNewNs dance.
    def create_element(name : String, context : Element? = nil, prefix_hint : String? = nil) : Element
      href, local = Element.parse_clark(name)
      if href
        if context && (prefix = context.find_ns_prefix(href))
          prefix, local_part = split_qname_for_creation(name, local, prefix)
          Element.new("#{prefix}:#{local_part}", prefix, local_part, href, [] of Attribute)
        else
          hint = prefix_hint || "ns#{Element.next_clark_number}"
          Element.new("#{hint}:#{local}", hint, local, href, [] of Attribute)
            .tap { |e| e.attributes << Attribute.new("xmlns:#{hint}", "xmlns", hint, XMLNS_NAMESPACE_URI, href, true) }
        end
      elsif name.includes?(':')
        prefix, local_part = name.split(':', 2)
        uri = context.try(&.in_scope_namespaces[prefix]?)
        Element.new(name, prefix, local_part, uri, [] of Attribute)
      else
        Element.new(name, nil, name, nil, [] of Attribute)
      end
    end

    private def split_qname_for_creation(name : String, local : String, prefix : String) : {String, String}
      {prefix, local}
    end

    def create_text(content : String) : Text
      Text.new(content)
    end

    # Monotonic document order for mutation-created nodes. Structural
    # mutations can place a new node before existing ones, so a plain
    # "max + 1" would hand out orders that contradict document order; the
    # whole document is renumbered in traversal order instead.
    def allocate_order(node : Node | Attribute) : Int32
      renumber
      node.doc_order
    end

    # Fast path for the common "append at the end" mutation: when *pred*
    # (the node the new node follows in document order) was the document's
    # last node *before the insertion* - *prev_last*, snapshotted by the
    # caller before it spliced the node in - the new node simply takes the
    # next orders instead of paying the full-tree renumber pass. Any other
    # position falls back to renumber.
    def allocate_order_after(node : Node | Attribute, pred : Node | Attribute, prev_last : Node | Attribute) : Int32
      if pred.same?(prev_last)
        # The inserted node lands after the current maximum, so its whole
        # subtree takes the next orders in sequence. Reassigning the subtree
        # (not just the node) is what keeps freshly built elements - whose
        # attributes were created before the element was attached - ordered.
        assign_order(node, prev_last.doc_order + 1)
      else
        renumber
      end
      node.doc_order
    end

    # The node holding the maximum doc_order. Order stays monotonic with
    # document position across mutations: every insertion either renumbers
    # or appends after the current maximum, and unlink only removes nodes
    # (the relative order of the survivors is untouched).
    def deepest_last : (Node | Attribute)?
      if last = misc_after.last?
        return deepest_last_of(last)
      end
      if r = @root
        return deepest_last_of(r)
      end
      if d = @doctype
        return d
      end
      if last = misc_before.last?
        return deepest_last_of(last)
      end
      nil
    end

    # Deepest, last node of *start*'s subtree in document order: attributes
    # order between their element and its children, and the last child's
    # subtree precedes anything after it.
    def deepest_last_of(start : Node | Attribute) : Node | Attribute
      n = start
      while n.is_a?(Element)
        if child = n.children.last?
          n = child
        elsif attr = n.attributes.last?
          return attr
        else
          return n
        end
      end
      n
    end

    # Assigns doc_order to every node and attribute in document order
    # (pre-order traversal, attributes immediately after their element).
    def renumber : Nil
      counter = 0
      misc_before.each do |misc|
        counter = assign_order(misc, counter)
      end
      if d = @doctype
        d.doc_order = counter
        counter += 1
      end
      if r = @root
        counter = assign_order(r, counter)
      end
      misc_after.each do |misc|
        counter = assign_order(misc, counter)
      end
    end

    private def assign_order(n : Node | Attribute, counter : Int32) : Int32
      n.doc_order = counter
      counter += 1
      if n.is_a?(Element)
        n.attributes.each do |attr|
          attr.doc_order = counter
          counter += 1
        end
        n.children.each do |child|
          counter = assign_order(child, counter)
        end
      end
      counter
    end

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
      to_xml(io, pretty: false)
    end

    def to_xml(pretty : Bool, indent_size : Int32 = 2) : String
      String.build { |io| to_xml(io, pretty, indent_size) }
    end

    # *pretty* mirrors libxml2's XML::SaveOptions::FORMAT: elements whose
    # children are all elements/comments/PIs get one child per line with
    # *indent_size*-space indentation; text-bearing content is inline.
    def to_xml(io : IO, pretty : Bool, indent_size : Int32 = 2) : Nil
      misc_before.each &.to_xml(io, pretty, 0, indent_size)
      if d = doctype
        d.to_xml(io)
        io << "\n" if pretty
      end
      if r = root
        r.to_xml(io, pretty, 0, indent_size)
      end
      misc_after.each &.to_xml(io, pretty, 0, indent_size)
      io << "\n" if pretty
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

    def []?(name : String) : String?
      self[name]
    end

    def elements : Array(Element)
      children.select(Element)
    end

    # ------------------------------------------------------------------
    # mutation API

    # Appends *node* as the last child (moving it out of any existing
    # parent first - libxml2's xmlAddChild move semantics). Adjacent text
    # nodes are coalesced, mirroring xmlAddChild, so a mutated document
    # re-parses to the same tree it serializes to.
    def append_child(node : Node) : Node
      node.unlink if node.parent_node
      if node.is_a?(Text) && (last = children.last?) && last.is_a?(Text)
        last.content += node.content
        return last
      end
      doc = document
      if doc
        # Snapshot the current maximum and the new node's document-order
        # predecessor BEFORE splicing the node in - afterwards deepest_last
        # would descend into the new node (whose fresh attributes still
        # carry order 0).
        prev_last = doc.deepest_last
        pred = children.last? ? doc.deepest_last_of(children.last) : (attributes.last? || self)
        node.parent_node = self
        children << node
        if pl = prev_last
          doc.allocate_order_after(node, pred, pl)
        else
          doc.allocate_order(node)
        end
      else
        node.parent_node = self
        children << node
      end
      node
    end

    # Replaces the entire child list with a single text node - the
    # element-content setter the real module's `node.text = value` uses.
    def text=(value : String) : Nil
      children.dup.each(&.unlink)
      append_child(Text.new(value)) unless value.empty?
    end

    # Sets attribute *name* (Clark `{uri}local` or plain) to *value*,
    # declaring the namespace on this element when no in-scope binding
    # exists (xmlSetNsProp + xmlNewNs semantics).
    def set_attribute(name : String, value : String) : Nil
      href, local = Element.parse_clark(name)
      if href
        prefix = find_ns_prefix(href)
        unless prefix
          prefix = "ns#{Element.next_clark_number}"
          append_attribute_ordered(Attribute.new("xmlns:#{prefix}", "xmlns", prefix, XMLNS_NAMESPACE_URI, href, true))
        end
        pos = attributes.index { |a| a.local_name == local && a.namespace_uri == href }
        if pos
          replacement = Attribute.new("#{prefix}:#{local}", prefix, local, href, value, true)
          replacement.doc_order = attributes[pos].doc_order
          attributes[pos] = replacement
        else
          append_attribute_ordered(Attribute.new("#{prefix}:#{local}", prefix, local, href, value, true))
        end
      else
        pos = attributes.index { |a| a.prefix.nil? && a.local_name == name }
        if pos
          replacement = Attribute.new(name, nil, name, nil, value, true)
          replacement.doc_order = attributes[pos].doc_order
          attributes[pos] = replacement
        else
          append_attribute_ordered(Attribute.new(name, nil, name, nil, value, true))
        end
      end
    end

    # Appends an attribute at the end of the attribute list and gives it a
    # document order. The attribute lands right after the element's current
    # last attribute (or the element itself), so the order allocation can
    # take the O(depth) fast path when that spot is also the document's
    # document-order maximum.
    private def append_attribute_ordered(attr : Attribute) : Nil
      doc = document
      if doc
        prev_last = doc.deepest_last
        pred = attributes.last? || self
      end
      attributes << attr
      if doc
        if prev_last && pred
          doc.allocate_order_after(attr, pred, prev_last)
        else
          doc.allocate_order(attr)
        end
      end
    end

    # Removes attribute *name* (Clark or plain) when present.
    def delete_attribute(name : String) : Nil
      href, local = Element.parse_clark(name)
      if href
        attributes.reject! { |a| a.local_name == local && a.namespace_uri == href }
      else
        attributes.reject! { |a| a.prefix.nil? && a.local_name == name }
      end
    end

    # Reads attribute *name* (Clark or plain).
    def attribute_value(name : String) : String?
      href, local = Element.parse_clark(name)
      if href
        attributes.find { |a| a.local_name == local && a.namespace_uri == href }.try(&.value)
      else
        self[local]?
      end
    end

    # The prefix bound to *href* on this element or its nearest ancestor.
    def find_ns_prefix(href : String) : String?
      n : Node? = self
      while n
        if n.is_a?(Element)
          n.attributes.each do |a|
            if a.prefix == "xmlns"
              return a.local_name if a.value == href
            elsif a.prefix.nil? && a.local_name == "xmlns"
              return "" if a.value == href
            end
          end
        end
        n = n.parent_node
      end
      nil
    end

    # In-scope namespace bindings (prefix -> href) from the nearest
    # element upward; nearer bindings win.
    def in_scope_namespaces : Hash(String, String)
      chain = [] of Element
      n : Node? = self
      while n
        chain << n if n.is_a?(Element)
        n = n.parent_node
      end
      ns = Hash(String, String).new
      chain.reverse_each do |element|
        element.attributes.each do |a|
          if a.prefix == "xmlns"
            ns[a.local_name] = a.value
          elsif a.prefix.nil? && a.local_name == "xmlns"
            if !a.value.empty?
              ns[""] = a.value
            else
              ns.delete("")
            end
          end
        end
      end
      ns
    end

    # libxml2's xmlGetNodePath: /ancestor/local[n] with the [n] index
    # counted among same-name siblings (omitted when unique); attributes
    # append /@name.
    def node_path : String
      segments = [] of String
      n : Node? = self
      while n
        case node = n
        when Element
          parent = node.parent_node
          if parent.is_a?(Document)
            segments.unshift("/#{node.name}")
            n = nil
            next
          end
          same = 0
          position = 0
          element_index = 0
          parent.as(Element).children.each do |sibling|
            next unless sibling.is_a?(Element)
            same += 1 if sibling.name == node.name
            position = element_index if sibling.same?(node)
            element_index += 1
          end
          segments.unshift(same > 1 ? "#{node.name}[#{position + 1}]" : node.name)
          n = parent
        when Attribute
          segments.unshift("@#{node.name}")
          n = nil
        else
          n = node.parent_node
        end
      end
      segments.join("/")
    end

    # Splits a Clark-notation name into {uri, local}; nil uri for plain
    # names.
    def self.parse_clark(name : String) : {String?, String}
      if name.starts_with?('{') && (i = name.index('}'))
        {name[1...i], name[(i + 1)..]}
      else
        {nil, name}
      end
    end

    @@clark_counter = 0

    def self.next_clark_number : Int32
      @@clark_counter += 1
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
      to_xml(io, pretty: false, depth: 0, indent_size: 2)
    end

    def to_xml(io : IO, pretty : Bool, depth : Int32, indent_size : Int32) : Nil
      io << '<' << name
      attributes.each do |a|
        io << ' ' << a.name << "=\"" << KXML.escape_attribute(a.value) << '"'
      end
      if children.empty?
        io << "/>"
        return
      end
      # libxml2 FORMAT: a parent whose children are all elements,
      # comments or PIs gets one child per line; any text/CDATA child
      # keeps the whole child list inline.
      format_children = pretty && children.all? do |child|
        child.is_a?(Element) || child.is_a?(Comment) || child.is_a?(ProcessingInstruction)
      end
      io << '>'
      if format_children
        pad = " " * ((depth + 1) * indent_size)
        children.each do |child|
          io << "\n" << pad
          child.to_xml(io, pretty, depth + 1, indent_size)
        end
        io << "\n" << (" " * (depth * indent_size))
      else
        children.each &.to_xml(io, pretty, depth + 1, indent_size)
      end
      io << "</" << name << '>'
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

  # A synthesized namespace node for XPath's namespace axis: the DOM
  # stores namespaces as attributes, but `namespace::*` must surface them
  # as nodes whose name is the prefix ("" for the default) and whose
  # string-value is the URI. Never produced by the parser, only by XPath
  # evaluation over the element's in-scope bindings.
  class NamespaceNode < Node
    getter prefix : String?
    getter href : String
    getter owner : Element

    def initialize(@prefix : String?, @href : String, @owner : Element)
      @parent_node = owner
      @doc_order = owner.doc_order
    end

    def to_xml(io : IO) : Nil
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

  # Single-pass byte-driven escaping; the gsub chains this replaces paid one
  # full scan plus a fresh String allocation per escaped character class.
  # Non-ASCII bytes are copied verbatim (a parsed DOM holds valid UTF-8, and
  # the multi-byte length follows from the lead byte alone).
  private def self.append_escaped(builder : String::Builder, s : String, table : Array(String?)) : Nil
    bytes = s.bytesize
    pos = 0
    while pos < bytes
      b = s.byte_at(pos)
      if b < 0x80
        rep = table[b]
        if rep
          builder << rep
        else
          builder.write_byte(b)
        end
        pos += 1
      else
        len = b >= 0xF0 ? 4 : (b >= 0xE0 ? 3 : 2)
        builder.write(Slice.new(s.to_unsafe + pos, len))
        pos += len
      end
    end
  end

  private TEXT_ESCAPE_REPLACEMENTS = [
    nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil,
    nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil,
    nil, nil, nil, nil, nil, nil, "&amp;", nil, nil, nil, nil, nil, nil, nil, nil, nil,
    nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, "&lt;", nil, "&gt;", nil,
    nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil,
    nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil,
    nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil,
    nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil,
  ] of String?

  private ATTRIBUTE_ESCAPE_REPLACEMENTS = [
    nil, nil, nil, nil, nil, nil, nil, nil, nil, "&#9;", "&#10;", nil, nil, nil, nil, nil,
    nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil,
    nil, nil, "&quot;", nil, nil, nil, "&amp;", nil, nil, nil, nil, nil, nil, nil, nil, nil,
    nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, "&lt;", nil, nil, nil,
    nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil,
    nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil,
    nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil,
    nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil,
  ] of String?

  def self.escape_text(s : String) : String
    return s unless s.includes?('&') || s.includes?('<') || s.includes?('>')
    String.build(s.bytesize + 16) do |builder|
      append_escaped(builder, s, TEXT_ESCAPE_REPLACEMENTS)
    end
  end

  def self.escape_attribute(s : String) : String
    return s unless s.includes?('&') || s.includes?('<') || s.includes?('"') ||
                    s.includes?('\n') || s.includes?('\t')
    String.build(s.bytesize + 16) do |builder|
      append_escaped(builder, s, ATTRIBUTE_ESCAPE_REPLACEMENTS)
    end
  end
end
