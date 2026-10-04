require "json"
require "../response"
require "../http/paths"
require "../cache"
require "../cold_brew"
require "../../sugar_orm/tenancy"

# The request's tenant (ADR 0025). A tenant route binds the tenant its first
# path segment names; outside a request, `with` binds one, `without` reaches
# every tenant's rows on purpose, and `each` runs once per tenant. A
# `spawn`ed fiber starts without a tenant: wrap its work in `with`.
module Caramel::Tenancy
  # A tenant's address: a lowercase DNS label, so it can also become a subdomain.
  SLUG = /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
  # The JSON key that carries a job's tenant.
  CARRY_KEY = "caramel_tenant"

  # :nodoc:
  NO_TENANT = <<-TEXT
    No tenant is bound.
    Remediation: call tenant only in a tenant route or inside \
    Caramel::Tenancy.with(tenant) { … }.
    TEXT

  # The tenant a job was enqueued in was deleted before it ran.
  class Gone < Exception
    def initialize(id : Int64)
      super("The tenant #{id} this job was enqueued in no longer exists")
    end
  end

  # The bound tenant; raises SugarORM::Tenancy::Missing when there is none.
  def self.current : ::SugarORM::Tenancy::Tenant
    current? || raise ::SugarORM::Tenancy::Missing.new(NO_TENANT)
  end

  # The bound tenant, or nil.
  def self.current? : ::SugarORM::Tenancy::Tenant?
    Fiber.current.__sugar_tenant
  end

  # Runs the block in *tenant*: its statements see only *tenant*'s rows, and
  # its new rows belong to *tenant*. Returns the block's value.
  def self.with(tenant : ::SugarORM::Tenancy::Tenant, &)
    ::SugarORM::Tenancy.bind(tenant, false) { yield }
  end

  # Runs the block outside every tenant, reaching every tenant's rows on
  # purpose. Creating a tenanted row still needs `with`.
  def self.without(&)
    ::SugarORM::Tenancy.bind(nil, true) { yield }
  end

  # Runs the block once per tenant, with that tenant bound.
  def self.each(& : ::SugarORM::Tenancy::Tenant ->) : Nil
    ::SugarORM::Tenancy::Tenant.query.each do |tenant|
      Tenancy.with(tenant) { yield tenant }
    end
  end

  # :nodoc:
  # Runs the block with no tenant bound and the scope in place, as a central
  # request runs.
  def self.none(&)
    ::SugarORM::Tenancy.bind(nil, false) { yield }
  end

  # :nodoc:
  def self.bound? : Bool
    !Fiber.current.__sugar_tenant.nil?
  end

  # :nodoc:
  # Whether *slug* is a central route's first segment or a locale prefix.
  def self.reserved?(slug : String) : Bool
    return true if CENTRAL_SEGMENTS.includes?(slug)
    {% if ::Caramel.has_constant?("Locale") %}
      return false unless ::Caramel::I18n::PREFIX
      return ::Caramel::Locale.values.any? { |locale| locale.code.downcase == slug }
    {% end %}
    false
  end

  # :nodoc:
  # The tenant slug *path*'s first segment names, or nil for a central path.
  def self.slug_in(path : String) : String?
    slug = path.lchop('/').partition('/')[0]
    return if slug.empty? || !slug.matches?(SLUG) || reserved?(slug)
    slug
  end

  # :nodoc:
  # *path* without its first segment: `/acme/books` is `/books`, and `/acme`
  # is `/`.
  def self.unprefix(path : String) : String
    "/#{path.lchop('/').partition('/')[2]}"
  end

  # :nodoc:
  # *response*, whose streamed body, if any, runs in *tenant*.
  def self.streamed_in(tenant : ::SugarORM::Tenancy::Tenant, response : Response) : Response
    streamer = response.streamer || return response
    bound = Response::Streamer.new { |io| Tenancy.with(tenant) { streamer.call(io) } }
    Response.new(response.status, response.body, response.headers, bound)
  end

  # :nodoc:
  # *name* under the bound tenant's `t<id>:` prefix.
  def self.scoped(name : String) : String
    tenant = current? || return name
    "t#{tenant.__sugar_primary_value}:#{name}"
  end

  # :nodoc:
  # The tenant id a job's *payload* carries. jsonb reorders keys, so the
  # whole object is read.
  def self.carried_id(payload : String) : Int64?
    parser = JSON::PullParser.new(payload)
    id = nil
    parser.read_object do |key|
      if key == CARRY_KEY
        id = parser.read_int
      else
        parser.skip
      end
    end
    id
  end
end

module Caramel
  # *path* under the request tenant's `/SLUG` prefix, unless *resource* is a
  # central route's first segment.
  def self.tenant_path(path : String, of resource : String? = nil) : String
    return path if resource && Tenancy::CENTRAL_SEGMENTS.includes?(resource)
    tenant = Tenancy.current? || return path
    prefix = "/#{Tenancy.slug(tenant)}"
    return prefix if path == "/"
    path.starts_with?("/?") ? prefix + path.lchop('/') : prefix + path
  end

  module Cache
    # *key* under the bound tenant's prefix.
    def self.scoped(key : String) : String
      Tenancy.scoped(key)
    end
  end

  module ColdBrew
    # *name* under the bound tenant's prefix, within PostgreSQL's 63 characters.
    def self.channel(name : String) : String
      scoped = Tenancy.scoped(name)
      return scoped if scoped.size <= 63
      raise ArgumentError.new(
        "PubSub channel #{name.inspect} is #{scoped.size} characters once prefixed " \
        "with its tenant (#{scoped.inspect}); the limit is 63"
      )
    end

    # *payload* with the bound tenant's id under Tenancy::CARRY_KEY.
    def self.carry(payload : String) : String
      tenant = Tenancy.current? || return payload
      carried = %({"#{Tenancy::CARRY_KEY}":#{tenant.__sugar_primary_value})
      payload == "{}" ? "#{carried}}" : "#{carried},#{payload.lchop('{')}"
    end

    # Runs the block in the tenant *payload* carries, or with none bound.
    def self.carried(payload : String, &) : Nil
      id = Tenancy.carried_id(payload)
      return Tenancy.none { yield } unless id
      tenant = Tenancy.find(id) || raise Tenancy::Gone.new(id)
      Tenancy.with(tenant) { yield }
    end
  end
end
