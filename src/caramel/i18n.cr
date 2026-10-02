require "../caramel"
require "./i18n/plural"
require "./i18n/catalog"
require "./i18n/runtime"
require "./i18n/localized"

module Caramel::I18n
  # `require "caramel/i18n"` compiles the catalogs `Caramel.locales` names,
  # so an application that requires it must call it.
  macro finished
    {% unless ::Caramel.has_constant?("Locale") %}
      {% raise "require \"caramel/i18n\" needs Caramel.locales after the locale catalogs\n" +
               "Remediation: add these lines to config/application.cr, after " +
               "require \"caramel/i18n\":\n" +
               "  require \"../app/locales/*\"\n" +
               "  Caramel.locales default: \"en\"\n" %}
    {% end %}
  end
end
