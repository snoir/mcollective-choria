require "spec_helper"
require "mcollective/util/choria"

module MCollective
  module Util
    describe Choria do
      let(:choria) { Choria.new("production", nil, false) }
      let(:parsed_app) { JSON.parse(File.read("spec/fixtures/sample_app.json")) }

      before(:each) do
        choria.stubs(:say)
      end

      context "when making certificates" do
        before(:each) do
          choria.stubs(:certname).returns("rspec.cert")
          choria.stubs(:ssl_dir).returns("/ssl")
          choria.stubs(:puppetca_server).returns("puppetca")
        end

        describe "#waiting_for_cert?" do
          it "should correctly detect the waiting scenario" do
            choria.expects(:has_client_public_cert?).returns(true)
            expect(choria.waiting_for_cert?).to be_falsey

            choria.expects(:has_client_public_cert?).returns(false)
            choria.expects(:has_client_private_key?).returns(false)
            expect(choria.waiting_for_cert?).to be_falsey

            choria.expects(:has_client_public_cert?).returns(false)
            choria.expects(:has_client_private_key?).returns(true)
            expect(choria.waiting_for_cert?).to be_truthy
          end
        end

        describe "#attempt_fetch_cert" do
          it "should not overwrite existing certs" do
            choria.expects(:has_client_public_cert?).returns(true)
            choria.expects(:https).never
            expect(choria.attempt_fetch_cert).to be_truthy
          end

          it "should return false on failure" do
            choria.expects(:has_client_public_cert?).returns(false)
            stub_request(:get, "https://puppetca:8140/puppet-ca/v1/certificate/rspec.cert")
              .with(:headers => {"Accept" => "text/plain"})
              .to_return(:status => 404, :body => "success")

            File.expects(:open).never

            expect(choria.attempt_fetch_cert).to be_falsey
          end

          it "should write the retrieved cert" do
            cert = File.read("spec/fixtures/rip.mcollective.pem")
            file = StringIO.new
            File.expects(:open).with("/ssl/certs/rspec.cert.pem", "w", 0o0644).yields(file)

            choria.expects(:has_client_public_cert?).returns(false)
            stub_request(:get, "https://puppetca:8140/puppet-ca/v1/certificate/rspec.cert")
              .with(:headers => {"Accept" => "text/plain"})
              .to_return(:status => 200, :body => cert)

            expect(choria.attempt_fetch_cert).to be_truthy
            expect(file.string).to eq(cert)
          end
        end

        describe "#request_cert" do
          let(:key) { OpenSSL::PKey::RSA.new(File.read("spec/fixtures/rip.mcollective.key")) }
          let(:csr) { choria.create_csr("rspec.cert", "mcollective", key) }

          before(:each) do
            choria.stubs(:write_key).returns(key)
            choria.stubs(:write_csr).with(key).returns(csr.to_pem)
          end

          it "should submit the cert to puppet" do
            stub_request(:put, "https://puppetca:8140/puppet-ca/v1/certificate_request/rspec.cert?environment=production")
              .with(:headers => {"Content-Type" => "text/plain"}, :body => csr.to_pem)
              .to_return(:status => 200, :body => "success")

            expect(choria.request_cert).to be_truthy
          end

          it "should correctly handle failures" do
            stub_request(:put, "https://puppetca:8140/puppet-ca/v1/certificate_request/rspec.cert?environment=production")
              .with(:headers => {"Content-Type" => "text/plain"}, :body => csr.to_pem)
              .to_return(:status => [500, "Internal Server Error"], :body => "rspec fail")

            expect {
              choria.request_cert
            }.to raise_error("Failed to request certificate from puppetca: 500: Internal Server Error: rspec fail")
          end
        end

        describe "#write_csr" do
          it "should not overwrite existing CSRs" do
            choria.expects(:has_csr?).returns(true)
            expect {
              choria.write_csr(:x)
            }.to raise_error("Refusing to overwrite existing CSR in /ssl/certificate_requests/rspec.cert.pem")
          end

          it "should write the right CSR" do
            key = OpenSSL::PKey::RSA.new(File.read("spec/fixtures/rip.mcollective.key"))
            file = StringIO.new
            scsr = choria.create_csr("rspec.cert", "mcollective", key)

            File.expects(:open).with("/ssl/certificate_requests/rspec.cert.pem", "w", 0o0644).yields(file)
            choria.expects(:create_csr).with("rspec.cert", "mcollective", key).returns(scsr)

            csr = choria.write_csr(key)
            expect(csr).to eq(scsr.to_pem)
            expect(file.string).to eq(csr)
          end
        end

        describe "#create_csr" do
          it "should create a valid CSR" do
            key = OpenSSL::PKey::RSA.new(File.read("spec/fixtures/rip.mcollective.key"))
            csr = choria.create_csr("rspec.cert", "rspec", key)
            expect(csr.version).to be(0)
            expect(csr.public_key.to_pem).to eq(key.public_key.to_pem)
            expect(csr.subject.to_s).to eq("/CN=rspec.cert/OU=rspec")
          end
        end

        describe "#write_key" do
          it "should not overwrite existing keys" do
            choria.stubs(:has_client_private_key?).returns(true)

            expect {
              choria.write_key
            }.to raise_error("Refusing to overwrite existing key in /ssl/private_keys/rspec.cert.pem")
          end

          it "should write a 4096 bit pem" do
            key = OpenSSL::PKey::RSA.new(File.read("spec/fixtures/rip.mcollective.key"))
            file = StringIO.new

            File.expects(:open).with("/ssl/private_keys/rspec.cert.pem", "w", 0o0640).yields(file)
            choria.expects(:create_rsa_key).with(4096).returns(key)

            expect(choria.write_key).to be(key)
            expect(file.string).to eq(key.to_pem)
          end
        end
      end

      describe "#make_ssl_dirs" do
        it "should make the right dirs" do
          choria.stubs(:ssl_dir).returns("/ssl")
          FileUtils.expects(:mkdir_p).with("/ssl", :mode => 0o0771)
          FileUtils.expects(:mkdir_p).with("/ssl/certificate_requests", :mode => 0o0755)
          FileUtils.expects(:mkdir_p).with("/ssl/certs", :mode => 0o0755)
          FileUtils.expects(:mkdir_p).with("/ssl/public_keys", :mode => 0o0755)
          FileUtils.expects(:mkdir_p).with("/ssl/private_keys", :mode => 0o0750)
          FileUtils.expects(:mkdir_p).with("/ssl/private", :mode => 0o0750)

          choria.make_ssl_dirs
        end
      end

      describe "#csr_path" do
        it "should get the right path in ssl_dir" do
          choria.expects(:ssl_dir).returns("/ssl")
          choria.expects(:certname).returns("rspec")
          expect(choria.csr_path).to eq("/ssl/certificate_requests/rspec.pem")
        end
      end

      describe "#ca_path" do
        it "should get the right path in ssl_dir" do
          choria.expects(:ssl_dir).returns("/ssl")
          expect(choria.ca_path).to eq("/ssl/certs/ca.pem")
        end
      end

      describe "#client_public_cert" do
        it "should get the right path in ssl_dir" do
          choria.expects(:ssl_dir).returns("/ssl")
          choria.expects(:certname).returns("rspec")
          expect(choria.client_public_cert).to eq("/ssl/certs/rspec.pem")
        end
      end

      describe "#client_private_key" do
        it "should get the right path in ssl_dir" do
          choria.expects(:ssl_dir).returns("/ssl")
          choria.expects(:certname).returns("rspec")
          expect(choria.client_private_key).to eq("/ssl/private_keys/rspec.pem")
        end
      end

      describe "#certname" do
        it "should take identity for root" do
          Process.expects(:uid).returns(0)
          expect(choria.certname).to eq("rspec_identity")
        end

        it "should support USER environment" do
          choria.expects(:env_fetch).with("USER", "rspec_identity").returns("rip")
          choria.expects(:env_fetch).with("MCOLLECTIVE_CERTNAME", "rip.mcollective").returns("rip.mcollective")
          expect(choria.certname).to eq("rip.mcollective")
        end

        it "should be overridable by MCOLLECTIVE_CERTNAME" do
          choria.expects(:env_fetch).with("USER", "rspec_identity").returns("rspec_identity")
          choria.expects(:env_fetch).with("MCOLLECTIVE_CERTNAME", "rspec_identity.mcollective").returns("rip.mcollective")
          expect(choria.certname).to eq("rip.mcollective")
        end
      end

      describe "#ssl_dir" do
        it "should support windows" do
          Util.expects(:windows?).returns(true)
          expect(choria.ssl_dir).to eq('C:\ProgramData\PuppetLabs\puppet\etc\ssl')
        end

        it "should support root on unix" do
          Util.expects(:windows?).returns(false)
          Process.expects(:uid).returns(0)
          expect(choria.ssl_dir).to eq("/etc/puppetlabs/puppet/ssl")
        end

        it "should support users" do
          Util.expects(:windows?).returns(false)
          Process.expects(:uid).returns(500)
          File.expects(:expand_path).with("~/.puppetlabs/etc/puppet/ssl").returns("/rspec/.puppetlabs/etc/puppet/ssl")
          expect(choria.ssl_dir).to eq("/rspec/.puppetlabs/etc/puppet/ssl")
        end
      end

      describe "#puppet_port" do
        it "should get the option from config, default to 8140" do
          Config.instance.stubs(:pluginconf).returns("puppet.port" => "8141")
          expect(choria.puppet_port).to eq("8141")

          Config.instance.stubs(:pluginconf).returns({})
          expect(choria.puppet_port).to eq("8140")
        end
      end

      describe "#puppetca_server" do
        it "should ge the option from config, defualting to puppet" do
          Config.instance.stubs(:pluginconf).returns("puppet.ca" => "rspec.puppetca")
          expect(choria.puppetca_server).to eq("rspec.puppetca")

          Config.instance.stubs(:pluginconf).returns({})
          expect(choria.puppet_server).to eq("puppet")
        end
      end

      describe "#puppet_server" do
        it "should ge the option from config, defualting to puppet" do
          Config.instance.stubs(:pluginconf).returns("puppet.master" => "rspec.puppet")
          expect(choria.puppet_server).to eq("rspec.puppet")

          Config.instance.stubs(:pluginconf).returns({})
          expect(choria.puppet_server).to eq("puppet")
        end
      end

      describe "check_ssl_setup" do
        before(:each) do
          choria.stubs(:client_public_cert).returns(File.expand_path("spec/fixtures/rip.mcollective.pem"))
          choria.stubs(:client_private_key).returns(File.expand_path("spec/fixtures/rip.mcollective.key"))
          choria.stubs(:ca_path).returns(File.expand_path("spec/fixtures/ca_crt.pem"))
        end

        it "should by default find all files" do
          expect(choria.check_ssl_setup).to be_truthy
        end

        it "fail if any files are missing" do
          choria.expects(:client_public_cert).returns("/nonexisting")

          expect {
            choria.check_ssl_setup
          }.to raise_error("Client SSL is not correctly setup, please use 'mco request_cert'")
        end
      end

      describe "#fetch_environment" do
        before(:each) do
          choria.stubs(:client_public_cert).returns(File.expand_path("spec/fixtures/rip.mcollective.pem"))
          choria.stubs(:client_private_key).returns(File.expand_path("spec/fixtures/rip.mcollective.key"))
          choria.stubs(:ca_path).returns(File.expand_path("spec/fixtures/ca_crt.pem"))
        end

        it "should fetch the right environment over https expecting JSON" do
          stub_request(:get, "https://puppet:8140/puppet/v3/environment/production")
            .with(:headers => {"Accept" => "application/json"})
            .to_return(:status => [500, "Internal Server Error"], :body => "failed")

          expect {
            choria.fetch_environment
          }.to raise_error("Failed to make request to Puppet: 500: Internal Server Error: failed")
        end

        it "should report error for non 200 replies" do
          stub_request(:get, "https://puppet:8140/puppet/v3/environment/production")
            .to_return(:status => 200, :body => File.read("spec/fixtures/sample_app.json"))

          expect(choria.fetch_environment).to eq(parsed_app)
        end
      end

      describe "#https" do
        it "should support anonymous connections" do
          choria.stubs(:has_client_public_cert?).returns(false)
          choria.stubs(:has_client_private_key?).returns(false)
          choria.stubs(:ca_path).returns(File.expand_path("spec/fixtures/ca_crt.pem"))

          h = choria.https

          expect(h.use_ssl?).to be_truthy
          expect(h.verify_mode).to be(OpenSSL::SSL::VERIFY_PEER)
          expect(h.cert).to be_nil
          expect(h.key).to be_nil
          expect(h.ca_file).to eq(choria.ca_path)
        end

        it "should support unverified connections" do
          choria.stubs(:client_public_cert).returns(File.expand_path("spec/fixtures/rip.mcollective.pem"))
          choria.stubs(:client_private_key).returns(File.expand_path("spec/fixtures/rip.mcollective.key"))
          choria.stubs(:has_ca?).returns(false)

          h = choria.https

          expect(h.use_ssl?).to be_truthy
          expect(h.verify_mode).to be(OpenSSL::SSL::VERIFY_NONE)
          expect(h.cert.subject.to_s).to eq("/CN=rip.mcollective")
          expect(h.key.to_pem).to eq(File.read(choria.client_private_key))
        end

        it "should create a valid http client" do
          choria.stubs(:client_public_cert).returns(File.expand_path("spec/fixtures/rip.mcollective.pem"))
          choria.stubs(:client_private_key).returns(File.expand_path("spec/fixtures/rip.mcollective.key"))
          choria.stubs(:ca_path).returns(File.expand_path("spec/fixtures/ca_crt.pem"))

          h = choria.https

          expect(h.use_ssl?).to be_truthy
          expect(h.verify_mode).to be(OpenSSL::SSL::VERIFY_PEER)
          expect(h.cert.subject.to_s).to eq("/CN=rip.mcollective")
          expect(h.ca_file).to eq(choria.ca_path)
          expect(h.key.to_pem).to eq(File.read(choria.client_private_key))
        end
      end
    end
  end
end