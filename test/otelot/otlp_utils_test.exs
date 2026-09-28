defmodule Otelot.OtlpUtilsTest do
  use ExUnit.Case, async: true

  alias Otelot.OtlpUtils

  describe "to_kv_value/1" do
    test "encodes booleans as bool values" do
      assert OtlpUtils.to_kv_value(true) == {:bool_value, true}
      assert OtlpUtils.to_kv_value(false) == {:bool_value, false}
    end

    test "encodes other atoms as strings" do
      assert OtlpUtils.to_kv_value(:ok) == {:string_value, "ok"}
      assert OtlpUtils.to_kv_value(nil) == {:string_value, ""}
    end
  end
end
