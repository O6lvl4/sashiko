require_relative "test_helper"

# Module-level receivers are Ractor-shareable by default.
module ParallelHelpers
  def self.double(n) = n * 2
  def self.slow_triple(n)
    sleep(rand * 0.02)  # randomize completion order
    n * 3
  end
  def self.to_int(n) = n.to_i
end

class RactorTest < Minitest::Test
  def test_parallel_map_runs_items_in_parallel_ractors
    assert_equal(
      [2, 4, 6, 8],
      Sashiko::Ractor.parallel_map([1, 2, 3, 4], via: ParallelHelpers.method(:double)),
    )
  end

  def test_parallel_map_preserves_input_order_regardless_of_completion
    assert_equal(
      [30, 60, 90],
      Sashiko::Ractor.parallel_map([10, 20, 30], via: ParallelHelpers.method(:slow_triple)),
    )
  end

  def test_parallel_map_accepts_any_shareable_module_method
    assert_equal(
      [1, 2, 3],
      Sashiko::Ractor.parallel_map([1.0, 2.0, 3.0], via: ParallelHelpers.method(:to_int)),
    )
  end

  def test_parallel_map_rejects_non_shareable_receiver
    # An instance of a non-frozen class is not Ractor-shareable.
    obj = Object.new
    def obj.work(n) = n
    refute Ractor.shareable?(obj)

    assert_raises(Sashiko::Ractor::NonShareableReceiverError) do
      Sashiko::Ractor.parallel_map([1, 2], via: obj.method(:work))
    end
  end

  def test_parallel_map_requires_method_object
    assert_raises(ArgumentError) do
      Sashiko::Ractor.parallel_map([1, 2], via: ->(n) { n * 2 })
    end
  end
end
