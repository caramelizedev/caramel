require "../action"
require "../view"
require "../application"
require "../wording"
require "../../sugar_orm/changeset"
require "./runtime"

module Caramel
  # What views and actions read the request's tenant with (ADR 0025). Inside
  # `markup { … }` they fall through to the view or action.
  module Tenanted
    # The request's tenant.
    def tenant
      ::Caramel::Tenancy.current
    end

    # *path* under the request tenant's `/SLUG` prefix; resource path helpers
    # already add it.
    def tenant_path(path : String) : String
      ::Caramel.tenant_path(path)
    end
  end

  abstract class View
    include Tenanted
  end

  abstract struct Action
    include Tenanted
  end

  class Application
    # Finds the tenant a request's first path segment names and routes the
    # rest of its path in that tenant; an unknown tenant is 404. Any other
    # request is central and routes with no tenant bound, even on a fiber
    # that served a tenant before.
    private def tenanted(request : HTTP::Request, & : HTTP::Request -> Response) : Response
      slug = Tenancy.slug_in(request.path) || return Tenancy.none { yield request }
      tenant = begin
        Tenancy.find(slug)
      rescue error
        return failure(error, request)
      end
      return Router.not_found unless tenant
      request.path = Tenancy.unprefix(request.path)
      Tenancy.streamed_in(tenant, Tenancy.with(tenant) { yield request })
    end
  end
end

abstract class SugarORM::Changeset(T)
  # *field* is a tenant's address: a lowercase DNS label that no central
  # route or locale prefix uses.
  def validate_tenant_slug(field : T::Field) : Nil
    string(field) do |value|
      label = value.matches?(Caramel::Tenancy::SLUG)
      add_error(field, SugarORM::Wording.invalid_format) unless label
      add_error(field, SugarORM::Wording.taken) if Caramel::Tenancy.reserved?(value)
    end
  end
end
