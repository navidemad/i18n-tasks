# frozen_string_literal: true

require 'prism/visitor'
require_relative 'nodes'

# Implementation of Prism::Visitor (https://ruby.github.io/prism/rb/Prism/Visitor.html)
# It processes the parsed AST from Prism and creates a new AST with the nodes defined in prism_scanners/nodes.rb
# The only argument it receives is comments, which can be used for magic comments.
# It defines processing of arguments in a way that is needed for the translation calls.
# Any Rails-specific processing is added in the RailsVisitor class.

module I18n::Tasks::Scanners::PrismScanners
  class Visitor < Prism::Visitor # rubocop:disable Metrics/ClassLength
    def initialize(comments: nil)
      @private_methods = false
      @comment_translations_by_row = prepare_comments_by_line(comments)

      # Needs to have () because the Prism::Visitor has no arguments
      super()
    end

    def self.skip_prism_comment?(comments)
      comments.any? do |comment|
        content =
          comment.respond_to?(:slice) ? comment.slice : comment.location.slice
        content.include?(BaseNode::MAGIC_COMMENT_SKIP_PRISM)
      end
    end

    def prepare_comments_by_line(comments)
      return {} if comments.nil?

      comments.each_with_object({}) do |comment, by_row|
        content =
          comment.respond_to?(:slice) ? comment.slice : comment.location.slice
        next by_row unless content =~ BaseNode::MAGIC_COMMENT_PREFIX

        string =
          content.gsub(BaseNode::MAGIC_COMMENT_PREFIX, '').gsub('#', '').strip
        nodes =
          Prism
          .parse(string)
          .value
          .accept(RailsVisitor.new)
          .filter { |node| node.is_a?(TranslationNode) }

        next by_row if nodes.empty?

        by_row[comment.location.start_line] = nodes
        by_row
      end
    end

    def visit_statements_node(node)
      node.child_nodes.map { |n| visit(n) }.flatten
    end

    def visit_embedded_statements_node(node)
      visit(node.statements)
    end

    def visit_program_node(node)
      visit(node.statements)
    end

    def visit_module_node(node)
      ModuleNode.new(
        node: node,
        child_nodes: node.body.body.map { |n| visit(n) }
      )
    end

    def visit_class_node(node)
      class_object = ClassNode.new(node: node)

      node
        .body
        .body
        .map { |n| visit(n) }
        .each { |child_node| class_object.add_child_node(child_node) }

      class_object
    end

    def visit_instance_variable_write_node(node)
      node.child_nodes.map { |n| visit(n) }.flatten
    end

    def visit_local_variable_write_node(node)
      node.child_nodes.map { |n| visit(n) }.flatten
    end

    def visit_local_variable_target_node(node)
      node.child_nodes.map { |n| visit(n) }.flatten
    end

    def visit_multi_write_node(node)
      node.child_nodes.map { |n| visit(n) }.flatten
    end

    def visit_def_node(node)
      calls = visit(node.body)&.flatten || []

      DefNode.new(node: node, calls: calls, private_method: @private_methods)
    end

    def visit_if_node(node)
      node.child_nodes.compact.map { |n| visit(n) }
    end

    def visit_else_node(node)
      visit(node.statements)
    end

    def visit_elsif_node(node)
      visit_if_node(node)
    end

    def visit_and_node(node)
      [visit(node.left), visit(node.right)]
    end

    def visit_or_node(node)
      [visit(node.left), visit(node.right)]
    end

    def visit_lambda_node(node)
      LambdaNode.new(node: node, calls: node.body.child_nodes.map { |n| visit(n) })
    end

    def visit_block_node(node)
      calls = node.body.child_nodes.filter_map { |n| visit(n) }.flatten

      BlockNode.new(node: node, calls: calls)
    end

    def visit_call_node(node)
      # TODO: How to handle multiple comments for same row?
      comment_translations =
        @comment_translations_by_row[node.location.start_line - 1]

      case node.name
      when :private
        @private_methods = true
        node
      when :t, :t!, :translate, :translate!
        handle_translation_call(node, comment_translations)
      else
        CallNode.new(node: node, comment_translations: comment_translations)
      end
    end

    def visit_assoc_node(node)
      [visit(node.key), visit(node.value)].flatten
    end

    def visit_symbol_node(node)
      node.value
    end

    def visit_string_node(node)
      node.content
    end

    def visit_interpolated_string_node(node)
      parts = node.parts.map { |n| visit(n) }.flatten
      I18n::Tasks::Scanners::PrismScanners::InterpolatedStringNode.new(node: node, parts: parts)
    end

    def visit_integer_node(node)
      node.value
    end

    def visit_decimal_node(node)
      node.value
    end

    def visit_constant_read_node(node)
      node.name
    end

    def visit_arguments_node(node)
      keywords, array =
        node.arguments.partition { |n| n.type == :keyword_hash_node }

      array.map { |n| visit(n) }.flatten << visit(keywords.first)
    end

    def visit_array_node(node)
      node.elements.map { |n| visit(n) }.flatten
    end

    def visit_keyword_hash_node(node)
      hash = {}

      node.elements.each do |child|
        case child.type
        when :assoc_node
          # Cannot use visit_assoc since it flattens the result
          hash[visit(child.key)] = visit(child.value)
        else
          fail(ArgumentError, "Unexpected node type: #{child.type}")
        end
      end

      hash
    end

    def handle_translation_call(node, comment_translations)
      array_args, keywords = process_arguments(node)
      key = array_args.first

      # We cannot handle keys that are interpolated strings
      return CallNode.new(node: node, comment_translations: comment_translations) if key.is_a?(InterpolatedStringNode)

      receiver = visit(node.receiver) if node.receiver

      TranslationNode.new(
        node: node,
        key: key,
        receiver: receiver,
        options: keywords,
        comment_translations: comment_translations
      )
    end

    def process_arguments(node)
      return [], {} if node.nil?
      return [], {} unless node.respond_to?(:arguments)
      return [], {} if node.arguments.nil?

      keywords, other =
        visit(node.arguments).partition { |value| value.is_a?(Hash) }

      [other.compact, keywords.first || {}]
    end
  end
end
