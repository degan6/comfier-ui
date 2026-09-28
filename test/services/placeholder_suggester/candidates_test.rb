require 'test_helper'

class PlaceholderSuggester
  class CandidatesTest < ActiveSupport::TestCase
    test 'the link index knows both directions and ignores look-alike arrays' do
      graph = {
        '1' => { 'class_type' => 'A', 'inputs' => {} },
        '2' => { 'class_type' => 'B', 'inputs' => { 'in' => ['1', 0], 'size' => [512, 512], 'ghost' => ['9', 0] } }
      }
      links = LinkIndex.new(graph)

      assert_equal [LinkIndex::Edge.new(node: '2', input: 'in')], links.consumers('1')
      assert_equal '1', links.source('2', 'in')
      assert_nil links.source('2', 'size')
      assert_nil links.source('2', 'ghost')
    end

    test 'only literal scalars that are not placeholders become candidates' do
      graph = { '1' => { 'class_type' => 'X', 'inputs' => {
        'a' => 'text', 'b' => 3, 'c' => true, 'd' => ['1', 0], 'e' => [1, 2], 'f' => { 'k' => 1 }, 'g' => '{{seed}}',
        'h' => '{{ width }}', 'i' => nil
      } } }

      assert_equal %w[a b c], Candidates.call(graph).map(&:input)
    end

    test 'model filenames, wiring, empty strings, switches and internal settings are skipped' do
      graph = { '1' => { 'class_type' => 'X', 'inputs' => {
        'ckpt_name' => 'a.safetensors', 'clip_name2' => 'b.safetensors', 'sampler_name' => 'euler', 'type' => 'flux',
        'image' => '', 'tiled' => true, 'resolution' => 4096, 'crop' => 'center', 'seed' => 1, 'lyrics' => 'la'
      } } }

      reasons = Candidates.call(graph).to_h { [it.input, it.skip_reason] }

      assert_equal({ 'ckpt_name' => :model_or_wiring, 'clip_name2' => :model_or_wiring,
                     'sampler_name' => :model_or_wiring, 'type' => :model_or_wiring, 'image' => :empty,
                     'tiled' => :switch, 'resolution' => :fixed_setting, 'crop' => :fixed_setting,
                     'seed' => nil, 'lyrics' => nil }, reasons)
    end

    test 'text encoders learn which side of the sampler they feed' do
      roles = text_roles(JSON.parse(file_fixture('workflows/sd_txt2img.json').read), '6', '7')

      assert_equal({ '6' => :positive, '7' => :negative }, roles)
    end

    test 'a conditioning input is a pass-through unless the chain ends there' do
      graph = sampler_graph.merge(
        '20' => encoder('nothing'), '21' => { 'class_type' => 'ConditioningZeroOut',
                                              'inputs' => { 'conditioning' => ['20', 0] } }
      )
      graph['3']['inputs']['negative'] = ['21', 0]

      candidate = Candidates.call(graph).find { it.node == '20' }

      assert_equal :negative, candidate.role
      assert_equal ['feeds KSampler.negative'], candidate.hints
    end

    test 'an encoder feeding both sides is ambiguous and one feeding nothing is unknown' do
      graph = sampler_graph.merge('30' => encoder('shared'), '31' => encoder('orphan'))
      graph['3']['inputs'].merge!('positive' => ['30', 0], 'negative' => ['30', 0])

      assert_equal({ '30' => :ambiguous, '31' => :unknown }, text_roles(graph, '30', '31'))
    end

    test 'denoise hints say where the latent comes from' do
      empty = Candidates.call(JSON.parse(file_fixture('workflows/sd_txt2img.json').read))
      encoded = Candidates.call(JSON.parse(file_fixture('workflows/img2img.json').read))
      denoise = ->(candidates) { candidates.find { it.input == 'denoise' } }

      assert_equal :empty, denoise.call(empty).latent_source
      assert_equal ['latent from EmptyLatentImage (empty; txt2x)'], denoise.call(empty).hints
      assert_equal :encoded, denoise.call(encoded).latent_source
      assert_equal ['latent from VAEEncode (encoded image; img2img)'], denoise.call(encoded).hints
    end

    test 'latent tracing passes through intermediate latent nodes' do
      graph = sampler_graph.merge(
        '40' => { 'class_type' => 'VAEEncode', 'inputs' => { 'pixels' => ['41', 0] } },
        '41' => { 'class_type' => 'LoadImage', 'inputs' => { 'image' => 'a.png' } },
        '42' => { 'class_type' => 'SetLatentNoiseMask', 'inputs' => { 'samples' => ['40', 0], 'mask' => ['41', 1] } }
      )
      graph['3']['inputs']['latent_image'] = ['42', 0]

      assert_equal :encoded, Candidates.call(graph).find { it.input == 'denoise' }.latent_source
    end

    test 'a scheduler borrows the latent of the sampler it feeds' do
      denoise = Candidates.call(JSON.parse(file_fixture('workflows/flux.json').read)).find { it.input == 'denoise' }

      assert_equal '17', denoise.node
      assert_equal :empty, denoise.latent_source
    end

    private

    def sampler_graph
      {
        '3' => { 'class_type' => 'KSampler', 'inputs' => { 'denoise' => 1, 'positive' => ['6', 0],
                                                           'negative' => ['6', 0], 'latent_image' => ['5', 0] } },
        '5' => { 'class_type' => 'EmptyLatentImage', 'inputs' => { 'width' => 512 } },
        '6' => encoder('positive')
      }
    end

    def encoder(text) = { 'class_type' => 'CLIPTextEncode', 'inputs' => { 'text' => text } }

    def text_roles(graph, *nodes)
      Candidates.call(graph).select { it.input == 'text' && nodes.include?(it.node) }.to_h { [it.node, it.role] }
    end
  end
end
