require 'spec_helper'

module Bosh::Director::ConfigServer
  describe EnabledClient do
    subject(:client) { EnabledClient.new(http_client, director_name, logger) }
    let(:director_name) {'smurf_director_name'}
    let(:deployment_name) {'deployment_name'}
    let(:logger) { double('Logging::Logger') }
    let!(:deployment_model) { Bosh::Director::Models::Deployment.make(name: deployment_name) }

    def prepend_namespace(name)
      "/#{director_name}/#{deployment_name}/#{name}"
    end

    before do
      allow(logger).to receive(:info)
    end

    describe '#interpolate' do
      subject { client.interpolate(manifest_hash, deployment_name, interpolate_options) }
      let(:interpolate_options) do
        {
          :subtrees_to_ignore => ignored_subtrees
        }
      end
      let(:ignored_subtrees) {[]}
      let(:integer_placeholder) { {'name' => "/#{director_name}/#{deployment_name}/integer_placeholder", 'value' => 123, 'id' => '1'} }
      let(:instance_placeholder) { {'name' => "/#{director_name}/#{deployment_name}/instance_placeholder", 'value' => 'test1', 'id' => '2'} }
      let(:job_placeholder) { {'name' => "/#{director_name}/#{deployment_name}/job_placeholder", 'value' => 'test2', 'id' => '3'} }
      let(:env_placeholder) { {'name' => "/#{director_name}/#{deployment_name}/env_placeholder", 'value' => 'test3', 'id' => '4'} }
      let(:cert_placeholder) { {'name' => "/#{director_name}/#{deployment_name}/cert_placeholder", 'value' => {'ca' => 'ca_value', 'private_key'=> 'abc123'}, 'id' => '5'} }
      let(:mock_config_store) do
        {
          prepend_namespace('integer_placeholder') => generate_success_response(integer_placeholder.to_json),
          prepend_namespace('instance_placeholder') => generate_success_response(instance_placeholder.to_json),
          prepend_namespace('job_placeholder') => generate_success_response(job_placeholder.to_json),
          prepend_namespace('env_placeholder') => generate_success_response(env_placeholder.to_json),
          prepend_namespace('cert_placeholder') => generate_success_response(cert_placeholder.to_json),
        }
      end

      let(:http_client) { double('Bosh::Director::ConfigServer::HTTPClient') }
      let(:manifest_hash)  do
        {
          'name' => deployment_name,
          'properties' => {
            'name' => '((integer_placeholder))'
          },
          'instance_groups' =>           {
            'name' => 'bla',
            'jobs' => [
              {
                'name' => 'test_job',
                'properties' => { 'job_prop' => '((job_placeholder))' }
              }
            ]
          },
          'resource_pools' => [
            {'env' => {'env_prop' => '((env_placeholder))'} }
          ],
          'cert' => '((cert_placeholder))'
        }
      end

      before do
        mock_config_store.each do |name, value|
          allow(http_client).to receive(:get).with(name).and_return(value)
        end
      end

      context 'when absolute path is required' do
        it 'should raise error when name is not absolute' do
          expect{
            client.interpolate(manifest_hash, deployment_name, {subtrees_to_ignore: ignored_subtrees, must_be_absolute_name: true})
          }.to raise_error(Bosh::Director::ConfigServerIncorrectNameSyntax)
        end
      end

      it 'should return a new copy of the original manifest' do
        expect(client.interpolate(manifest_hash, deployment_name, {subtrees_to_ignore: ignored_subtrees})).to_not equal(manifest_hash)
      end

      it 'replaces all placeholders it finds in the hash passed' do
        expected_result = {
          'name' => 'deployment_name',
          'properties' => {
            'name' => 123
          },
          'instance_groups' =>           {
            'name' => 'bla',
            'jobs' => [
              {
                'name' => 'test_job',
                'properties' => { 'job_prop' => 'test2' }
              }
            ]
          },
          'resource_pools' => [
            {'env' => {'env_prop' => 'test3'} }
          ],
          'cert' => {
              'ca' => 'ca_value',
              'private_key'=> 'abc123'
          }
        }

        expect(subject).to eq(expected_result)
      end

      it 'creates placeholder_mapping entries for each placeholder in the manifest' do
        subject

        mappings = Bosh::Director::Models::PlaceholderMapping.all

        expect(mappings.count).to eq(4)

        [integer_placeholder, job_placeholder, env_placeholder, cert_placeholder].each do |placeholder|
          mapping = mappings.select { |mapping| mapping.placeholder_id == placeholder['id'] }.first
          expect(mapping.placeholder_name).to eq(placeholder['name'])
        end
      end

      it 'should raise a missing name error message when name is not found in the config_server' do
        allow(http_client).to receive(:get).with(prepend_namespace('missing_placeholder')).and_return(SampleNotFoundResponse.new)

        manifest_hash['properties'] = { 'name' => '((missing_placeholder))' }
        expect{
          subject
        }.to raise_error(
               Bosh::Director::ConfigServerMissingNames,
               "Failed to load placeholder names from the config server: #{prepend_namespace('missing_placeholder')}")
      end

      it 'should raise an unknown error when config_server returns any error other than a 404' do
        allow(http_client).to receive(:get).with(prepend_namespace('missing_placeholder')).and_return(SampleErrorResponse.new)

        manifest_hash['properties'] = { 'name' => '((missing_placeholder))' }
        expect{
          subject
        }.to raise_error(Bosh::Director::ConfigServerUnknownError)
      end

      context 'ignored subtrees' do
        #TODO pull out config server mocks into their own lets
        let(:mock_config_store) do
          {
            prepend_namespace('release_1_placeholder') => generate_success_response({'value' => 'release_1', 'id' => 1}.to_json),
            prepend_namespace('release_2_version_placeholder') => generate_success_response({'value' => 'v2', 'id' => 2}.to_json),
            prepend_namespace('job_name') => generate_success_response({'value' => 'spring_server', 'id' => 3}.to_json)
          }
        end

        let(:manifest_hash) do
          {
            'releases' => [
              {'name' => '((release_1_placeholder))', 'version' => 'v1'},
              {'name' => 'release_2', 'version' => '((release_2_version_placeholder))'}
            ],
            'instance_groups' => [
              {
                'name' => 'logs',
                'env' => { 'smurf' => '((smurf_placeholder))' },
                'jobs' => [
                  {
                    'name' => 'mysql',
                    'properties' => {'foo' => '((foo_place_holder))', 'bar' => {'smurf' => '((smurf_placeholder))'}}
                  },
                  {
                    'name' => '((job_name))'
                  }
                ],
                'properties' => {'a' => ['123', 45, '((secret_name))']}
              }
            ],
            'properties' => {
              'global_property' => '((something))'
            },
            'resource_pools' => [
              {
                'name' => 'resource_pool_name',
                'env' => {
                  'f' => '((f_placeholder))'
                }
              }
            ]
          }
        end

        let(:interpolated_manifest_hash) do
          {
            'releases' => [
              {'name' => 'release_1', 'version' => 'v1'},
              {'name' => 'release_2', 'version' => 'v2'}
            ],
            'instance_groups' => [
              {
                'name' => 'logs',
                'env' => {'smurf' => '((smurf_placeholder))'},
                'jobs' => [
                  {
                    'name' => 'mysql',
                    'properties' => {'foo' => '((foo_place_holder))', 'bar' => {'smurf' => '((smurf_placeholder))'}}
                  },
                  {
                    'name' => 'spring_server'
                  }
                ],
                'properties' => {'a' => ['123', 45, '((secret_name))']}
              }
            ],
            'properties' => {
              'global_property' => '((something))'
            },
            'resource_pools' => [
              {
                'name' => 'resource_pool_name',
                'env' => {
                  'f' => '((f_placeholder))'
                }
              }
            ]
          }
        end

        let(:ignored_subtrees) do
          index_type = Integer
          any_string = String

          ignored_subtrees = []
          ignored_subtrees << ['properties']
          ignored_subtrees << ['instance_groups', index_type, 'properties']
          ignored_subtrees << ['instance_groups', index_type, 'jobs', index_type, 'properties']
          ignored_subtrees << ['instance_groups', index_type, 'jobs', index_type, 'consumes', any_string, 'properties']
          ignored_subtrees << ['jobs', index_type, 'properties']
          ignored_subtrees << ['jobs', index_type, 'templates', index_type, 'properties']
          ignored_subtrees << ['jobs', index_type, 'templates', index_type, 'consumes', any_string, 'properties']
          ignored_subtrees << ['instance_groups', index_type, 'env']
          ignored_subtrees << ['jobs', index_type, 'env']
          ignored_subtrees << ['resource_pools', index_type, 'env']
          ignored_subtrees << ['name']
          ignored_subtrees
        end

        it 'should not replace values in ignored subtrees' do
          expect(subject).to eq(interpolated_manifest_hash)
        end
      end

      context 'when placeholders begin with !' do
        let(:manifest_hash) do
          {
            'name' => 'deployment_name',
            'properties' => {
              'age' => '((!integer_placeholder))'
            }
          }
        end

        it 'should strip the exclamation mark' do
          expected_result = {
            'name' => 'deployment_name',
            'properties' => {'age' => 123 }
          }
          expect(subject).to eq(expected_result)
        end
      end

      context 'when some placeholders have invalid name syntax' do
        let(:manifest_hash) do
          {
            'properties' => {
              'age' => '((I am an invalid name &%^))'
            }
          }
        end

        it 'raises an error' do
          expect{
            subject
          }. to raise_error(Bosh::Director::ConfigServerIncorrectNameSyntax)
        end
      end
    end

    describe '#interpolate_deployment_manifest' do
      let(:http_client) { double('Bosh::Director::ConfigServer::HTTPClient') }

      let(:ignored_subtrees) do
        index_type = Integer
        any_string = String

        ignored_subtrees = []
        ignored_subtrees << ['properties']
        ignored_subtrees << ['instance_groups', index_type, 'properties']
        ignored_subtrees << ['instance_groups', index_type, 'jobs', index_type, 'properties']
        ignored_subtrees << ['instance_groups', index_type, 'jobs', index_type, 'consumes', any_string, 'properties']
        ignored_subtrees << ['jobs', index_type, 'properties']
        ignored_subtrees << ['jobs', index_type, 'templates', index_type, 'properties']
        ignored_subtrees << ['jobs', index_type, 'templates', index_type, 'consumes', any_string, 'properties']
        ignored_subtrees << ['instance_groups', index_type, 'env']
        ignored_subtrees << ['jobs', index_type, 'env']
        ignored_subtrees << ['resource_pools', index_type, 'env']
        ignored_subtrees
      end

      it 'should call interpolate with the correct arguments' do
        expect(subject).to receive(:interpolate).with({'name' => 'smurf', 'properties' => { 'a' => '{{placeholder}}' }}, 'smurf', {subtrees_to_ignore: ignored_subtrees, must_be_absolute_name: false}).and_return({'name' => 'smurf'})
        result = subject.interpolate_deployment_manifest({'name' => 'smurf', 'properties' => { 'a' => '{{placeholder}}' } })
        expect(result).to eq({'name' => 'smurf'})
      end
    end

    describe '#interpolate_runtime_manifest' do
      let(:http_client) { double('Bosh::Director::ConfigServer::HTTPClient') }

      let(:ignored_subtrees) do
        index_type = Integer
        any_string = String

        ignored_subtrees = []
        ignored_subtrees << ['addons', index_type, 'properties']
        ignored_subtrees << ['addons', index_type, 'jobs', index_type, 'properties']
        ignored_subtrees << ['addons', index_type, 'jobs', index_type, 'consumes', any_string, 'properties']
        ignored_subtrees
      end

      it 'should call interpolate with the correct arguments' do
        expect(subject).to receive(:interpolate).with({'name' => '{{placeholder}}'}, nil, {subtrees_to_ignore: ignored_subtrees, must_be_absolute_name: true}).and_return({'name' => 'smurf'})
        result = subject.interpolate_runtime_manifest({'name' => '{{placeholder}}'})
        expect(result).to eq({'name' => 'smurf'})
      end
    end

    describe '#prepare_and_get_property' do
      let(:http_client) { double('Bosh::Director::ConfigServer::HTTPClient') }
      let(:ok_response) do
        response = SampleSuccessResponse.new
        response.body = {'value'=> 'hello'}.to_json
        response
      end

      context 'when property value provided is nil' do
        it 'returns default value' do
          expect(client.prepare_and_get_property(nil, 'my_default_value', 'some_type', deployment_name)).to eq('my_default_value')
        end
      end

      context 'when property value is NOT nil' do
        context 'when property value is NOT a placeholder (padded with brackets)' do
          it 'returns that property value' do
            expect(client.prepare_and_get_property('my_smurf', 'my_default_value', nil, deployment_name)).to eq('my_smurf')
            expect(client.prepare_and_get_property('((my_smurf', 'my_default_value', nil, deployment_name)).to eq('((my_smurf')
            expect(client.prepare_and_get_property('my_smurf))', 'my_default_value', 'whatever', deployment_name)).to eq('my_smurf))')
          end
        end

        context 'when property value is a placeholder (padded with brackets)' do
          context 'when placeholder syntax is invalid' do
            it 'raises an error' do
              expect{
                client.prepare_and_get_property('((invalid name $%$^))', 'my_default_value', nil, deployment_name)
              }. to raise_error(Bosh::Director::ConfigServerIncorrectNameSyntax)
            end
          end

          context 'when placeholder syntax is valid' do
            let(:the_placeholder) { '((my_smurf))' }
            let(:bang_placeholder) { '((!my_smurf))' }

            context 'when config server returns an error while checking for name' do
              it 'raises an error' do
                expect(http_client).to receive(:get).with(prepend_namespace('my_smurf')).and_return(SampleErrorResponse.new)
                expect{
                  client.prepare_and_get_property(the_placeholder, 'my_default_value', nil, deployment_name)
                }. to raise_error(Bosh::Director::ConfigServerUnknownError)
              end
            end

            context 'when value is found in config server' do
              it 'returns that property value as is' do
                expect(http_client).to receive(:get).with(prepend_namespace('my_smurf')).and_return(ok_response)
                expect(client.prepare_and_get_property(the_placeholder, 'my_default_value', nil, deployment_name)).to eq(the_placeholder)
              end

              it 'returns that property value as is when it starts with exclamation mark' do
                expect(http_client).to receive(:get).with(prepend_namespace('my_smurf')).and_return(ok_response)
                expect(client.prepare_and_get_property(bang_placeholder, 'my_default_value', nil, deployment_name)).to eq(bang_placeholder)
              end
            end

            context 'when value is NOT found in config server' do
              before do
                expect(http_client).to receive(:get).with(prepend_namespace('my_smurf')).and_return(SampleNotFoundResponse.new)
              end

              context 'when default is defined' do
                it 'returns the default value when type is nil' do
                  expect(client.prepare_and_get_property(the_placeholder, 'my_default_value', nil, deployment_name)).to eq('my_default_value')
                end

                it 'returns the default value when type is defined' do
                  expect(client.prepare_and_get_property(the_placeholder, 'my_default_value', 'some_type', deployment_name)).to eq('my_default_value')
                end

                it 'returns the default value when type is defined and generatable' do
                  expect(client.prepare_and_get_property(the_placeholder, 'my_default_value', 'password', deployment_name)).to eq('my_default_value')
                end

                context 'when placeholder starts with exclamation mark' do
                  it 'returns the default value when type is nil' do
                    expect(client.prepare_and_get_property(bang_placeholder, 'my_default_value', nil, deployment_name)).to eq('my_default_value')
                  end

                  it 'returns the default value when type is defined' do
                    expect(client.prepare_and_get_property(bang_placeholder, 'my_default_value', 'some_type', deployment_name)).to eq('my_default_value')
                  end

                  it 'returns the default value when type is defined and generatable' do
                    expect(client.prepare_and_get_property(bang_placeholder, 'my_default_value', 'password', deployment_name)).to eq('my_default_value')
                  end
                end
              end

              context 'when default is NOT defined i.e nil' do
                let(:full_key) { prepend_namespace('my_smurf') }
                let(:default_value) { nil }
                context 'when type is generatable' do
                  context 'when type is password' do
                    let(:type){ 'password'}
                    it 'generates a password and returns the user provided value' do
                      expect(http_client).to receive(:post).with(full_key, {'type' => 'password'}).and_return(SampleSuccessResponse.new)
                      expect(client.prepare_and_get_property(the_placeholder, default_value, type, deployment_name)).to eq(the_placeholder)
                    end

                    it 'throws an error if generation of password errors' do
                      expect(http_client).to receive(:post).with(full_key, {'type' => 'password'}).and_return(SampleErrorResponse.new)
                      expect(logger).to receive(:error)

                      expect{
                        client.prepare_and_get_property(the_placeholder, default_value, type, deployment_name)
                      }. to raise_error(Bosh::Director::ConfigServerPasswordGenerationError, "Config Server failed to generate password for '#{full_key}'")
                    end

                    context 'when placeholder starts with exclamation mark' do
                      it 'generates a password and returns the user provided value' do
                        expect(http_client).to receive(:post).with(full_key, {'type' => 'password'}).and_return(SampleSuccessResponse.new)
                        expect(client.prepare_and_get_property(bang_placeholder, default_value, type, deployment_name)).to eq(bang_placeholder)
                      end
                    end
                  end

                  context 'when type is certificate' do
                    let(:full_key) {prepend_namespace('my_smurf')}
                    let(:type){'certificate'}
                    let(:dns_record_names) do
                      %w(*.fake-name1.network-a.simple.bosh *.fake-name1.network-b.simple.bosh)
                    end

                    let(:options) do
                      {
                        :dns_record_names => dns_record_names
                      }
                    end

                    let(:post_body) do
                      {
                        'type' => 'certificate',
                        'parameters' => {
                          'common_name' => dns_record_names[0],
                          'alternative_names' => dns_record_names
                        }
                      }
                    end

                    it 'generates a certificate and returns the user provided placeholder' do
                      expect(http_client).to receive(:post).with(full_key, post_body).and_return(SampleSuccessResponse.new)
                      expect(client.prepare_and_get_property(the_placeholder, default_value, type, deployment_name, options)).to eq(the_placeholder)
                    end

                    it 'throws an error if generation of certficate errors' do
                      expect(http_client).to receive(:post).with(full_key, post_body).and_return(SampleErrorResponse.new)
                      expect(logger).to receive(:error)

                      expect{
                        client.prepare_and_get_property(the_placeholder, default_value, type, deployment_name, options)
                      }. to raise_error(Bosh::Director::ConfigServerCertificateGenerationError, "Config Server failed to generate certificate for '#{full_key}'")
                    end

                    context 'when placeholder starts with exclamation mark' do
                      it 'generates a certificate and returns the user provided placeholder' do
                        expect(http_client).to receive(:post).with(full_key, post_body).and_return(SampleSuccessResponse.new)
                        expect(client.prepare_and_get_property(bang_placeholder, default_value, type, deployment_name, options)).to eq(bang_placeholder)
                      end
                    end
                  end
                end

                context 'when type is NOT generatable' do
                  let(:type){ 'cat'}
                  it 'returns that the user provided value as is' do
                    expect(client.prepare_and_get_property(the_placeholder, default_value, type, deployment_name)).to eq(the_placeholder)
                  end
                end
              end
            end
          end
        end
      end
    end

    def generate_success_response(body)
      result = SampleSuccessResponse.new
      result.body = body
      result
    end
  end

  describe DisabledClient do

    subject(:disabled_client) { DisabledClient.new }
    let(:deployment_name) { 'smurf_deployment' }

    describe '#interpolate' do
      let(:src) do
        {
          'test' => 'smurf',
          'test2' => '((placeholder))'
        }
      end

      it 'returns src as is' do
        expect(disabled_client.interpolate(src, deployment_name)).to eq(src)
      end
    end

    describe '#interpolate_deployment_manifest' do
      let(:manifest) do
        {
          'test' => 'smurf',
          'test2' => '((placeholder))'
        }
      end

      it 'returns manifest as is' do
        expect(disabled_client.interpolate_deployment_manifest(manifest)).to eq(manifest)
      end
    end

    describe '#interpolate_runtime_manifest' do
      let(:manifest) do
        {
          'test' => 'smurf',
          'test2' => '((placeholder))'
        }
      end

      it 'returns manifest as is' do
        expect(disabled_client.interpolate_runtime_manifest(manifest)).to eq(manifest)
      end
    end

    describe '#prepare_and_get_property' do
      it 'returns manifest property value if defined' do
        expect(disabled_client.prepare_and_get_property('provided prop', 'default value is here', nil, deployment_name)).to eq('provided prop')
        expect(disabled_client.prepare_and_get_property('provided prop', 'default value is here', nil, deployment_name, {})).to eq('provided prop')
        expect(disabled_client.prepare_and_get_property('provided prop', 'default value is here', nil, deployment_name, {'whatever' => 'hello'})).to eq('provided prop')
      end
      it 'returns default value when manifest value is nil' do
        expect(disabled_client.prepare_and_get_property(nil, 'default value is here', nil, deployment_name)).to eq('default value is here')
        expect(disabled_client.prepare_and_get_property(nil, 'default value is here', nil, deployment_name, {})).to eq('default value is here')
        expect(disabled_client.prepare_and_get_property(nil, 'default value is here', nil, deployment_name, {'whatever' => 'hello'})).to eq('default value is here')
      end
    end
  end

  class SampleSuccessResponse < Net::HTTPOK
    attr_accessor :body

    def initialize
      super(nil, Net::HTTPOK, nil)
    end
  end

  class SampleNotFoundResponse < Net::HTTPNotFound
    def initialize
      super(nil, Net::HTTPNotFound, 'Not Found Brah')
    end
  end

  class SampleErrorResponse < Net::HTTPForbidden
    def initialize
      super(nil, Net::HTTPForbidden, 'There was a problem.')
    end
  end
end
