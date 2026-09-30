require "./external_url"
require "../sugar_orm/changeset"

# Caramel adds this validator to SugarORM changesets, so SugarORM itself does
# not depend on Caramel.
abstract class SugarORM::Changeset(T)
  # A changed string must be a URL `redirect_external` accepts
  # (`Caramel::ExternalURL`), so what is saved can be redirected to.
  def validate_url(field : T::Field,
                   message : String = "must be an absolute http or https URL") : Nil
    string(field) do |value|
      add_error(field, message) unless Caramel::ExternalURL.valid?(value)
    end
  end
end
