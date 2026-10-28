require "big"
require "./codec"

module SugarORM
  # Stores a `BigDecimal` in a `numeric(P,S)` column, P digits in all and S of them after
  # the point. A column of this codec takes a Range in `where`, and orders by value. The
  # text written is plain digits, `-12.5`, never an exponent; a value with more than S
  # decimals, or more than P - S digits before the point, is refused at the write, so
  # PostgreSQL never rounds or overflows one. Reading `numeric::text` gives the same
  # plain digits back. Requiring this file links GMP, so SugarORM does not require it:
  # an application that stores decimals requires `sugar_orm/decimal` itself.
  #
  #     field rate : BigDecimal, codec: SugarORM::DecimalCodec(20, 8)
  struct DecimalCodec(P, S)
    ORDERABLE = true

    def self.sql_type : String
      "numeric(#{P},#{S})"
    end

    def self.encode(value : BigDecimal) : String
      text = Decimal.plain(value)
      Decimal.fits(text, P, S) || raise ArgumentError.new(
        "#{text} does not fit numeric(#{P},#{S}): at most #{S} decimals and " \
        "#{P - S} digits before the point"
      )
      text
    end

    def self.decode(text : String) : BigDecimal
      BigDecimal.new(text)
    end
  end

  # The plain text of a decimal, shared by the codec and the values over it.
  module Decimal
    # A decimal written with digits and at most one point: `0`, `-12.5`, `100.25`.
    TEXT = /\A-?\d+(?:\.\d+)?\z/

    # *value* as plain digits with no exponent and no trailing zeros after the point:
    # `0.5`, `-12`, `12345678901234567890.12345678`.
    def self.plain(value : BigDecimal) : String
      digits = value.value.abs.to_s
      scale = value.scale
      if scale > 0
        digits = digits.rjust(scale + 1, '0')
        whole = digits[0, digits.size - scale]
        fraction = digits[digits.size - scale..].rstrip('0')
        digits = fraction.empty? ? whole : "#{whole}.#{fraction}"
      end
      value.value < 0 ? "-#{digits}" : digits
    end

    # Whether *text*, plain digits as `plain` writes them, fits `numeric(P,S)`: the zero
    # before the point of `0.5` is not a digit PostgreSQL counts.
    def self.fits(text : String, precision : Int, scale : Int) : Bool
      whole, _, fraction = text.lchop('-').partition('.')
      fraction.size <= scale && whole.lstrip('0').size <= precision - scale
    end
  end
end
