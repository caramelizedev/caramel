module Caramel
  # A Content-Security-Policy: each directive with its sources, in order.
  #
  #     Caramel.content_security_policy.add("script-src", "https://js.stripe.com")
  #
  # An action changes its own response's copy with `content_security_policy`
  # (ADR 0037).
  class ContentSecurityPolicy
    DIRECTIVE = /\A[a-z]+(?:-[a-z]+)*\z/
    # Printable ASCII without spaces, ',' or ';'.
    SOURCE = /\A[\x21-\x2B\x2D-\x3A\x3C-\x7E]+\z/
    NONE   = "'none'"

    # `'self'` only, images also from `data:` URLs, no framing and no plugins.
    def self.default : self
      new({
        "default-src"     => ["'self'"],
        "script-src"      => ["'self'"],
        "style-src"       => ["'self'"],
        "img-src"         => ["'self'", "data:"],
        "base-uri"        => ["'self'"],
        "form-action"     => ["'self'"],
        "frame-ancestors" => [NONE],
        "object-src"      => [NONE],
      })
    end

    def initialize(@directives = {} of String => Array(String))
    end

    # Adds *sources* to *directive*. A `-src` directive the policy does not have yet
    # starts from `default-src`'s sources, so `add("connect-src", "https://api.example")`
    # keeps `'self'`. Adding a source drops `'none'`, and a source already present is
    # not added twice.
    def add(directive : String, *sources : String) : self
      check_directive(directive)
      sources.each { |source| check_source(source) }
      current = @directives[directive]? || inherited(directive)
      current.delete(NONE)
      sources.each { |source| current << source unless current.includes?(source) }
      @directives[directive] = current
      self
    end

    def add(directive : String) : self
      raise ArgumentError.new("add needs at least one source")
    end

    # Replaces *directive*'s sources.
    def set(directive : String, *sources : String) : self
      check_directive(directive)
      sources.each { |source| check_source(source) }
      @directives[directive] = sources.to_a
      self
    end

    # Writes *directive* with no source, as `upgrade-insecure-requests` is.
    def set(directive : String) : self
      check_directive(directive)
      @directives[directive] = [] of String
      self
    end

    def delete(directive : String) : self
      check_directive(directive)
      @directives.delete(directive)
      self
    end

    # A copy that changes without touching this policy.
    def dup : self
      copy = {} of String => Array(String)
      @directives.each { |directive, sources| copy[directive] = sources.dup }
      self.class.new(copy)
    end

    def to_s(io : IO) : Nil
      first = true
      @directives.each do |directive, sources|
        io << "; " unless first
        first = false
        io << directive
        sources.each { |source| io << ' ' << source }
      end
    end

    private def inherited(directive : String) : Array(String)
      return [] of String unless directive.ends_with?("-src") && directive != "default-src"
      @directives["default-src"]?.try(&.dup) || [] of String
    end

    private def check_directive(directive : String) : Nil
      return if directive.matches?(DIRECTIVE)
      raise ArgumentError.new("Content-Security-Policy directive names are lowercase " \
                              "words joined by hyphens, got #{directive.inspect}")
    end

    private def check_source(source : String) : Nil
      return if source.matches?(SOURCE)
      raise ArgumentError.new("Content-Security-Policy sources are printable ASCII " \
                              "without spaces, ',' or ';', got #{source.inspect}")
    end
  end

  @@content_security_policy = ContentSecurityPolicy.default

  # The policy every response carries unless its action changes its own copy.
  # Change it in config/application.cr, before the application is built.
  def self.content_security_policy : ContentSecurityPolicy
    @@content_security_policy
  end
end
