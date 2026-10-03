require "uri"
require "../response"
require "../action"
require "../wording"
require "./request_input"
require "./request_context"

module Caramel
  # Routes are declared once with `Caramel::Router.draw`, which checks every
  # route against its action's contract at compile time and defines
  # `AppRouter` in the calling module.
  module Router
    MAX_SEGMENTS = 32

    # A route; `tenant` routes live under a tenant's `/SLUG` prefix.
    record Entry,
      method : String,
      path : String,
      action : String,
      contract : String,
      ingress : Ingress = Ingress::DEFAULT,
      tenant : Bool = false

    # The route a request's real method and path select. It is found before
    # the body is read, so the route's ingress decides how to read it; an
    # unmatched request reads with DEFAULT, so it still meets the CSRF check.
    # `tenant` says which routes it was matched against.
    record Match,
      path : String,
      segments : Segments?,
      index : Int32,
      mask : UInt8,
      ingress : Ingress,
      tenant : Bool = false

    METHOD_BITS = {
      "GET"    => 1_u8,
      "POST"   => 2_u8,
      "PUT"    => 4_u8,
      "PATCH"  => 8_u8,
      "DELETE" => 16_u8,
    }

    def self.method_bit(method : String) : UInt8
      METHOD_BITS[method == "HEAD" ? "GET" : method]? || 0_u8
    end

    # The methods an Allow header lists, in order, with their bits; HEAD
    # shares GET's.
    ALLOW_BITS = {
      "GET"    => 1_u8,
      "HEAD"   => 1_u8,
      "POST"   => 2_u8,
      "PUT"    => 4_u8,
      "PATCH"  => 8_u8,
      "DELETE" => 16_u8,
    }

    def self.allow_header(mask : UInt8) : String
      String.build do |io|
        first = true
        ALLOW_BITS.each do |method, bit|
          next if mask & bit == 0
          io << ", " unless first
          io << method
          first = false
        end
      end
    end

    def self.head(response : Response) : Response
      headers = response.headers.dup
      if response.streamer
        headers.delete("Content-Length")
      else
        headers["Content-Length"] = response.body.bytesize.to_s
      end
      Response.new(response.status, "", headers)
    end

    # No route matches the path, or a route parameter does not fit its
    # field. The body is `Caramel::Wording.not_found`, which a locale catalog
    # can translate.
    def self.not_found : Response
      Response.new(404, Wording.not_found)
    end

    # A route's authenticator refused the request; it learns nothing more.
    def self.unauthorized : Response
      headers = HTTP::Headers{
        "Content-Type"  => "text/plain; charset=utf-8",
        "Cache-Control" => "no-store",
      }
      Response.new(401, "Unauthorized", headers)
    end

    # A `_method` override aimed at a route that reads its body differently.
    def self.override_refused(allowed : UInt8) : Response
      headers = HTTP::Headers{"Allow" => allow_header(allowed)}
      Response.new(405, "Method override is not allowed for this route", headers)
    end

    module Dispatcher
      abstract def match(request : HTTP::Request) : Match
      abstract def dispatch(context : RequestContext, match : Match) : Response

      def dispatch(context : RequestContext) : Response
        dispatch(context, match(context.request))
      end
    end

    # Byte offsets of each path segment. Parsing validates escapes and
    # control characters without allocating.
    struct Segments
      @bounds = StaticArray(Int32, 64).new(0)
      getter size = 0

      # ameba:disable Metrics/CyclomaticComplexity -- a single-pass path scanner
      def self.parse(path : String) : Segments?
        bytes = path.to_slice
        return if bytes.empty? || bytes[0] != '/'.ord
        index = 0
        while index < bytes.size
          byte = bytes[index]
          if byte == '%'.ord
            return unless index + 2 < bytes.size
            high = hex(bytes[index + 1])
            low = hex(bytes[index + 2])
            return unless high && low
            decoded = high * 16 + low
            return if decoded < 0x20 || decoded == 0x7F || decoded == '/'.ord || decoded == '\\'.ord
            index += 3
          else
            return if byte < 0x20 || byte == 0x7F || byte == '\\'.ord
            index += 1
          end
        end
        segments = new
        return segments if bytes.size == 1
        start = 1
        loop do
          stop = start
          while stop < bytes.size && bytes[stop] != '/'.ord
            stop += 1
          end
          break unless segments.push(start, stop)
          break if stop == bytes.size
          start = stop + 1
        end
        segments
      end

      private def self.hex(byte : UInt8) : Int32?
        case byte
        when '0'.ord..'9'.ord then byte.to_i32 - '0'.ord
        when 'a'.ord..'f'.ord then byte.to_i32 - 'a'.ord + 10
        when 'A'.ord..'F'.ord then byte.to_i32 - 'A'.ord + 10
        end
      end

      # Returns false once the path exceeds MAX_SEGMENTS; `size` then reports
      # one more than the limit so the caller can answer 404.
      protected def push(start : Int32, stop : Int32) : Bool
        if @size == MAX_SEGMENTS
          @size += 1
          return false
        end
        @bounds[@size * 2] = start
        @bounds[@size * 2 + 1] = stop
        @size += 1
        true
      end

      def bytesize(index : Int32) : Int32
        @bounds[index * 2 + 1] - @bounds[index * 2]
      end

      def equals?(path : String, index : Int32, literal : String) : Bool
        path.to_slice[@bounds[index * 2], bytesize(index)] == literal.to_slice
      end

      def decode(path : String, index : Int32) : String
        value = URI.decode(path.byte_slice(@bounds[index * 2], bytesize(index)))
        raise RequestInput::InvalidEncoding.new("Malformed path") unless value.valid_encoding?
        value
      end
    end

    # A segment trie built once from the compile-time route table. Static
    # children win over the parameter child; matching backtracks, so
    # `/teams/new/members` can still reach `/teams/:team_id/members`.
    # Tenant routes have a root of their own.
    class Tree
      class Node
        getter statics = [] of {String, Node}
        property param : Node? = nil
        getter terminals = [] of {UInt8, Int32}
      end

      getter entries : Array(Entry)

      def initialize(@entries : Array(Entry))
        @root = Node.new
        @tenant_root = Node.new
        @entries.each_with_index do |entry, index|
          node = entry.tenant ? @tenant_root : @root
          entry.path.lchop('/').split('/', remove_empty: true).each do |segment|
            node = if segment.starts_with?(':')
                     node.param ||= Node.new
                   elsif found = node.statics.find { |(literal, _)| literal == segment }
                     found[1]
                   else
                     Node.new.tap { |child| node.statics << {segment, child} }
                   end
          end
          node.terminals << {Router.method_bit(entry.method), index}
        end
      end

      # Returns the route index (-1 for none) and every method allowed at the
      # matching paths, for 405 responses.
      def match(path : String,
                segments : Segments,
                method : String,
                tenant : Bool = false) : {Int32, UInt8}
        walk(tenant ? @tenant_root : @root, path, segments, 0, Router.method_bit(method))
      end

      # Matches the request's own method (HEAD as GET), before any override.
      def route(path : String, method : String, tenant : Bool = false) : Match
        segments = Segments.parse(path)
        unless segments && segments.size <= MAX_SEGMENTS
          return Match.new(path, segments, -1, 0_u8, Ingress::DEFAULT, tenant)
        end

        index, mask = match(path, segments, method, tenant)
        ingress = index >= 0 ? @entries[index].ingress : Ingress::DEFAULT
        Match.new(path, segments, index, mask, ingress, tenant)
      end

      # Every method the routes at this path take, whatever the request's.
      def allowed(path : String, segments : Segments, tenant : Bool = false) : UInt8
        match(path, segments, "", tenant)[1]
      end

      private def walk(node : Node,
                       path : String,
                       segments : Segments,
                       depth : Int32,
                       bit : UInt8) : {Int32, UInt8}
        mask = 0_u8
        if depth == segments.size
          node.terminals.each do |(route_bit, index)|
            mask |= route_bit
            return {index, mask} if route_bit == bit
          end
          return {-1, mask}
        end
        node.statics.each do |(literal, child)|
          next unless segments.equals?(path, depth, literal)
          index, allowed = walk(child, path, segments, depth + 1, bit)
          return {index, allowed} if index >= 0
          mask |= allowed
          break
        end
        if (child = node.param) && segments.bytesize(depth) > 0
          index, allowed = walk(child, path, segments, depth + 1, bit)
          return {index, allowed} if index >= 0
          mask |= allowed
        end
        {-1, mask}
      end
    end

    # Expands in the calling module: route actions resolve like any other
    # constant there, and the generated `AppRouter` is defined there.
    #
    # Checks that need only the route text run here, where each statement
    # still carries its source location, so errors highlight the route line.
    #
    # One `tenant App::Account, by: :slug do … end` block may hold the routes
    # that live under a tenant's `/SLUG` prefix; it needs `caramel/tenancy`.
    macro draw(&block)
      {% if block.body.is_a?(Expressions) %}
        {% statements = block.body.expressions %}
      {% elsif block.body.is_a?(Nop) %}
        {% statements = [] of Nil %}
      {% else %}
        {% statements = [block.body] %}
      {% end %}
      {% flat = [] of Nil %}
      {% tenants = [] of Nil %}
      {% tenant = nil %}
      {% for stmt in statements %}
        {% if stmt.is_a?(Call) && stmt.receiver.is_a?(Nop) && stmt.name.stringify == "tenant" %}
          {% named = stmt.named_args.is_a?(Nop) ? [] of Nil : stmt.named_args %}
          {% by = nil %}
          {% if named.size == 1 && named[0].name.stringify == "by" %}
            {% by = named[0].value %}
          {% end %}
          {% model = stmt.args.size == 1 ? stmt.args[0] : nil %}
          {% unless model.is_a?(Path) && by.is_a?(SymbolLiteral) && stmt.block.is_a?(Block) %}
            {% stmt.raise "tenant expects tenant App::Model, by: :field do ... end, " +
                          "like tenant App::Account, by: :slug do" %}
          {% end %}
          {% if tenant %}
            {% stmt.raise "Caramel::Router.draw takes one tenant block" %}
          {% end %}
          {% unless ::Caramel.has_constant?("Tenancy") %}
            {% stmt.raise "tenant ... do needs require \"caramel/tenancy\".\n" +
                          "Remediation: add it after require \"caramel\" " +
                          "in config/application.cr." %}
          {% end %}
          {% tenant_at = "#{stmt.filename.id}:#{stmt.line_number}:#{stmt.column_number}" %}
          {% tenant = {model: model, by: by, at: tenant_at} %}
          {% body = stmt.block.body %}
          {% inner = [body] %}
          {% if body.is_a?(Expressions) %}
            {% inner = body.expressions %}
          {% elsif body.is_a?(Nop) %}
            {% inner = [] of Nil %}
          {% end %}
          {% for route in inner %}
            {% flat << route %}
            {% tenants << true %}
          {% end %}
        {% else %}
          {% flat << stmt %}
          {% tenants << false %}
        {% end %}
      {% end %}
      {% routes = [] of Nil %}
      {% locations = [] of Nil %}
      {% verbs = ["get", "post", "put", "patch", "delete"] %}
      {% for stmt, i in flat %}
        {% in_tenant = tenants[i] %}
        {% ok = false %}
        {% if stmt.is_a?(Call) && stmt.receiver.is_a?(Nop) && stmt.block.is_a?(Nop) %}
          {% if verbs.includes?(stmt.name.stringify) && stmt.args.size == 2 %}
            {% ok = stmt.args[0].is_a?(StringLiteral) && stmt.args[1].is_a?(Path) %}
          {% end %}
        {% end %}
        {% unless ok %}
          {% stmt.raise "Caramel::Router.draw accepts only get, post, put, patch " +
                        "and delete declarations with a string path " +
                        "and an Action constant, and one tenant block: #{stmt}" %}
        {% end %}
        {% method = stmt.name.stringify.upcase %}
        {% path = stmt.args[0] %}
        {% invalid = "Invalid route path '#{path.id}': static segments use " +
                     "[A-Za-z0-9._~-] and parameters use :snake_case" %}
        {% unless path.starts_with?("/") %}
          {% path.raise invalid %}
        {% end %}
        {% segments = path == "/" ? [] of Nil : path[1..-1].split("/") %}
        {% names = [] of Nil %}
        {% for segment in segments %}
          {% if segment.starts_with?(":") %}
            {% unless segment =~ /\A:[a-z_][a-z0-9_]*\z/ %}
              {% path.raise invalid %}
            {% end %}
            {% name = segment[1..-1] %}
            {% if names.includes?(name) %}
              {% path.raise "Route '#{path.id}' repeats parameter ':#{name.id}'" %}
            {% end %}
            {% names << name %}
          {% else %}
            {% unless segment =~ /\A[A-Za-z0-9._~-]+\z/ %}
              {% path.raise invalid %}
            {% end %}
          {% end %}
        {% end %}
        {% if segments.size > 32 %}
          {% path.raise "Route '#{path.id}' exceeds 32 path segments" %}
        {% end %}
        {% for earlier in routes %}
          {% same_size = earlier[2].size == segments.size %}
          {% if earlier[0] == method && same_size && earlier[3] == in_tenant %}
            {% overlap = true %}
            {% identical = true %}
            {% mixed = nil %}
            {% for segment, position in segments %}
              {% other = earlier[2][position] %}
              {% if segment.starts_with?(":") && other.starts_with?(":") %}
              {% elsif !segment.starts_with?(":") && !other.starts_with?(":") %}
                {% if segment != other %}
                  {% overlap = false %}
                {% end %}
              {% else %}
                {% identical = false %}
                {% if mixed == nil %}
                  {% mixed = segment.starts_with?(":") ? "earlier" : "later" %}
                {% end %}
              {% end %}
            {% end %}
            {% if overlap && identical %}
              {% stmt.raise "\n\n❌ DUPLICATE ROUTE\n" +
                            "'#{method.id} #{earlier[1].id}' and " +
                            "'#{method.id} #{path.id}' match the same requests\n" %}
            {% end %}
            {% if overlap && mixed == "later" %}
              {% stmt.raise "\n\n❌ AMBIGUOUS ROUTE ORDER\n" +
                            "'#{method.id} #{path.id}' must be declared before " +
                            "'#{method.id} #{earlier[1].id}'\n" %}
            {% end %}
          {% end %}
        {% end %}
        {% routes << {method, path, segments, in_tenant} %}
        {% line_column = "#{stmt.line_number}:#{stmt.column_number}" %}
        {% locations << (stmt.filename ? "#{stmt.filename.id}:#{line_column.id}" : "") %}
      {% end %}
      {% central = [] of Nil %}
      {% if tenant %}
        {% for route in routes %}
          {% if !route[3] && !route[2].empty? %}
            {% first = route[2][0] %}
            {% if first.starts_with?(":") %}
              {% route[1].raise "Route '#{route[1].id}' starts with a parameter, " +
                                "which would take every tenant's address.\n" +
                                "Remediation: give it a static first segment, " +
                                "or move it into the tenant block." %}
            {% end %}
            {% unless central.includes?(first) %}
              {% central << first %}
            {% end %}
          {% end %}
        {% end %}
        {% for route in routes %}
          {% if route[3] && !route[2].empty? && central.includes?(route[2][0]) %}
            {% route[1].raise "Route '#{route[1].id}' in the tenant block starts with " +
                              "'#{route[2][0].id}', as a central route does; " +
                              "a link could not tell them apart.\n" +
                              "Remediation: rename one of them." %}
          {% end %}
        {% end %}
      {% end %}
      {% if tenant %}
        {% declared = {
             model:   tenant[:model],
             by:      tenant[:by],
             central: "[#{central.map(&.stringify).join(", ").id}] of String".id,
             at:      tenant[:at],
           } %}
      {% else %}
        {% declared = nil %}
      {% end %}
      __caramel_router_draw({{ locations }}, {{ tenants }}, {{ declared }}) do
        {% for route in flat %}
          {{ route }}
        {% end %}
      end
    end
  end
end

# Implementation of `Caramel::Router.draw`, which has already checked the
# route text. A receiverless top-level macro expands in the caller's scope, so
# relative action paths resolve there. `locations` holds each route's source
# location for the checks that need resolved types, and `tenants` whether it
# lives in the tenant block. `tenant`, when the routes have a tenant block,
# names its model, which resolves here too, for Caramel::Tenancy.declare.
macro __caramel_router_draw(locations, tenants, tenant, &block)
  {% if block.body.is_a?(Expressions) %}
    {% statements = block.body.expressions %}
  {% elsif block.body.is_a?(Nop) %}
    {% statements = [] of Nil %}
  {% else %}
    {% statements = [block.body] %}
  {% end %}
  {% routes = [] of Nil %}
  {% for stmt, i in statements %}
    {% method = stmt.name.stringify.upcase %}
    {% path = stmt.args[0] %}
    {% action = stmt.args[1] %}
    {% where = locations[i] == "" ? "" : "  --> #{locations[i].id}\n" %}
    {% segments = path == "/" ? [] of Nil : path[1..-1].split("/") %}
    {% params = [] of Nil %}
    {% for segment, position in segments %}
      {% if segment.starts_with?(":") %}
        {% params << {segment[1..-1], position} %}
      {% end %}
    {% end %}
    {% type = action.resolve? %}
    {% unless type %}
      {% raise "Compile Error: Action '#{action}' is undefined.\n" +
               where +
               "Remediation: define `struct #{action} < Caramel::Action` " +
               "or correct the route's action constant.\n" %}
    {% end %}
    {% unless type < ::Caramel::Action %}
      {% raise "Compile Error: '#{action}' must inherit from Caramel::Action.\n" +
               where +
               "Remediation: declare it as `struct #{action} < Caramel::Action` " +
               "(or your application's base action).\n" %}
    {% end %}
    {% contract = type.constant("Contract") %}
    {% unless contract %}
      {% raise "Compile Error: '#{action}' must define an explicit " +
               "`contract do ... end` block.\n" +
               where +
               "Remediation: add `contract do ... end` inside #{action}; " +
               "it may be empty.\n" %}
    {% end %}
    {% contract_location = contract.constant("CARAMEL_CONTRACT_LOCATION") %}
    {% contract_where = contract_location ? "Contract: #{contract_location.id}\n" : "" %}
    {% for param in params %}
      {% t = param[0] %}
      {% suggest = (t == "id" || t.ends_with?("_id")) ? "Int64" : "String" %}
      {% field = contract.constant("CARAMEL_FIELD_#{t.upcase.id}") %}
      {% unless field %}
        {% raise "\n\n❌ ROUTE CONTRACT MISMATCH\n" +
                 "Route: '#{path.id}' defines parameter ':#{t.id}'\n" +
                 "Action: '#{action.id}::Contract' is missing 'field #{t.id} : Type'\n" +
                 where + contract_where +
                 "Remediation: add `field #{t.id} : #{suggest.id}` " +
                 "to the contract block of #{action.id}.\n" %}
      {% end %}
      {% scalar = field[1] %}
      {% unless ["String", "Int32", "Int64"].includes?(scalar) && !field[2] && !field[3] %}
        {% declared = "#{t.id} : #{scalar.id}#{field[2] ? "?".id : "".id}" %}
        {% raise "\n\n❌ ROUTE CONTRACT TYPE MISMATCH\n" +
                 "Route: '#{path.id}' parameter ':#{t.id}' binds to " +
                 "'#{action.id}::Contract' field '#{declared.id}'\n" +
                 "Path parameters must be non-nilable String, Int32 or Int64 fields " +
                 "without defaults\n" +
                 where + contract_where +
                 "Remediation: declare `field #{t.id} : #{suggest.id}` " +
                 "(String, Int32 or Int64; no `?` and no `default:`).\n" %}
      {% end %}
    {% end %}
    {% summaries = [] of Nil %}
    {% for constant in contract.constants %}
      {% if constant.stringify.starts_with?("CARAMEL_FIELD_") %}
        {% summaries << contract.constant(constant)[4].id %}
      {% end %}
    {% end %}
    {% summary = summaries.join(" ") %}
    {% written = action.stringify %}
    {% routes << {method, path, type, segments, params, summary, written, tenants[i]} %}
  {% end %}

  {% if tenant %}
    {% resolved = tenant[:model].resolve? %}
    ::Caramel::Tenancy.declare(
      {{ resolved ? "::#{resolved}".id : tenant[:model] }},
      by: {{ tenant[:by] }},
      central: {{ tenant[:central] }},
      at: {{ tenant[:at] }},
    )
  {% end %}

  class AppRouter
    include ::Caramel::Router::Dispatcher

    TREE = ::Caramel::Router::Tree.new([
      {% for route in routes %}
        ::Caramel::Router::Entry.new(
          {{ route[0] }}, {{ route[1] }}, {{ route[6] }}, {{ route[5] }},
          ::{{ route[2] }}::CARAMEL_INGRESS, {{ route[7] }},
        ),
      {% end %}
    ] of ::Caramel::Router::Entry)

    def self.routes : Array(::Caramel::Router::Entry)
      TREE.entries
    end

    def match(request : HTTP::Request) : ::Caramel::Router::Match
      {% if tenants.includes?(true) %}
        TREE.route(request.path, request.method, ::Caramel::Tenancy.bound?)
      {% else %}
        TREE.route(request.path, request.method)
      {% end %}
    end

    def dispatch(context : ::Caramel::RequestContext,
                 match : ::Caramel::Router::Match) : ::Caramel::Response
      path = match.path
      segments = match.segments
      return ::Caramel::Response.new(400, "Malformed path") unless segments
      return ::Caramel::Router.not_found if segments.size > ::Caramel::Router::MAX_SEGMENTS
      index, mask = match.index, match.mask
      if override = context.input.method_override
        index, mask = TREE.match(path, segments, override, match.tenant)
        # The body was read, and CSRF checked, as the POST's route reads it.
        if index >= 0 && !TREE.entries[index].ingress.reads_like?(match.ingress)
          allowed = TREE.allowed(path, segments, match.tenant)
          return ::Caramel::Router.override_refused(allowed)
        end
      end
      if index < 0
        return ::Caramel::Router.not_found if mask == 0
        headers = HTTP::Headers{"Allow" => ::Caramel::Router.allow_header(mask)}
        return ::Caramel::Response.new(405, "Method not allowed", headers)
      end
      {% if routes.empty? %}
        response = ::Caramel::Router.not_found
      {% else %}
        response = case index
        {% for route, index in routes %}
          when {{ index }} then __caramel_route_{{ index }}(context, path, segments)
        {% end %}
        else
          ::Caramel::Router.not_found
        end
      {% end %}
      context.request.method == "HEAD" ? ::Caramel::Router.head(response) : response
    end

    {% for route, index in routes %}
      private def __caramel_route_{{ index }}(
        context : ::Caramel::RequestContext,
        path : String,
        segments : ::Caramel::Router::Segments,
      ) : ::Caramel::Response
        {% if route[4].empty? %}
          context.input.route_params = {} of String => String
        {% else %}
          context.input.route_params = {
            {% for param in route[4] %}
              {{ param[0] }} => segments.decode(path, {{ param[1] }}),
            {% end %}
          }
        {% end %}
        action = ::{{ route[2] }}.new(context)
        return ::Caramel::Router.unauthorized unless action.__caramel_authenticated?
        contract = ::{{ route[2] }}::Contract.parse(context.input)
        {% unless route[4].empty? %}
          if contract.route_error?({{ route[4].map { |param| param[0] } }})
            return ::Caramel::Router.not_found
          end
        {% end %}
        return action.render_contract_failure(contract) unless contract.valid?
        action.respond(action.handle(contract))
      end
    {% end %}
  end
end
