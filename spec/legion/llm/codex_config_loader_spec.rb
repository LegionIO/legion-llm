# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/call/codex_config_loader'

RSpec.describe Legion::LLM::CodexConfigLoader do
  let(:auth_path) { described_class::CODEX_AUTH }
  let(:env_default) { ['env://OPENAI_API_KEY', 'env://CODEX_API_KEY'] }

  before do
    allow(File).to receive(:exist?).and_call_original
  end

  describe '.load' do
    context 'when auth file does not exist' do
      before { allow(File).to receive(:exist?).with(auth_path).and_return(false) }

      it 'returns nil without changing settings' do
        expect(described_class.load).to be_nil
        expect(Legion::LLM.settings[:providers][:openai][:api_key]).to eq(env_default)
      end
    end

    context 'when auth file exists with chatgpt mode and valid token' do
      let(:token_payload) { Base64.urlsafe_encode64({ exp: Time.now.to_i + 3600 }.to_json).delete('=') }
      let(:token) { "eyJhbGciOiJSUzI1NiJ9.#{token_payload}.signature" }
      let(:auth_json) do
        {
          auth_mode:      'chatgpt',
          OPENAI_API_KEY: nil,
          tokens:         {
            access_token:  token,
            refresh_token: 'rt_abc',
            account_id:    'acct_123'
          }
        }.to_json
      end

      before do
        allow(File).to receive(:exist?).with(auth_path).and_return(true)
        allow(File).to receive(:read).with(auth_path).and_return(auth_json)
        stub_const('ENV', ENV.to_h.except('OPENAI_API_KEY', 'CODEX_API_KEY'))
      end

      it 'imports the access token as openai api_key' do
        described_class.load
        expect(Legion::LLM.settings[:providers][:openai][:api_key]).to eq(token)
      end

      it 'does not overwrite an existing api_key' do
        Legion::LLM.settings[:providers][:openai][:api_key] = 'sk-existing'
        described_class.load
        expect(Legion::LLM.settings[:providers][:openai][:api_key]).to eq('sk-existing')
      end

      it 'does not overwrite when api_key is a single env:// placeholder that resolves to a value' do
        stub_const('ENV', ENV.to_h.merge('OPENAI_API_KEY' => 'sk-from-env'))
        Legion::LLM.settings[:providers][:openai][:api_key] = 'env://OPENAI_API_KEY'
        described_class.load
        expect(Legion::LLM.settings[:providers][:openai][:api_key]).to eq('env://OPENAI_API_KEY')
      end

      it 'imports when api_key is a single env:// placeholder that resolves to nothing' do
        stub_const('ENV', ENV.to_h.except('OPENAI_API_KEY'))
        Legion::LLM.settings[:providers][:openai][:api_key] = 'env://OPENAI_API_KEY'
        described_class.load
        expect(Legion::LLM.settings[:providers][:openai][:api_key]).to eq(token)
      end
    end

    context 'when auth_mode is not chatgpt' do
      let(:auth_json) { { auth_mode: 'api_key', OPENAI_API_KEY: 'sk-test' }.to_json }

      before do
        allow(File).to receive(:exist?).with(auth_path).and_return(true)
        allow(File).to receive(:read).with(auth_path).and_return(auth_json)
      end

      it 'does not import anything' do
        described_class.load
        expect(Legion::LLM.settings[:providers][:openai][:api_key]).to eq(env_default)
      end
    end

    context 'when the token is expired' do
      let(:token_payload) { Base64.urlsafe_encode64({ exp: Time.now.to_i - 3600 }.to_json).delete('=') }
      let(:token) { "eyJhbGciOiJSUzI1NiJ9.#{token_payload}.signature" }
      let(:auth_json) do
        { auth_mode: 'chatgpt', tokens: { access_token: token } }.to_json
      end

      before do
        allow(File).to receive(:exist?).with(auth_path).and_return(true)
        allow(File).to receive(:read).with(auth_path).and_return(auth_json)
      end

      it 'skips the expired token' do
        described_class.load
        expect(Legion::LLM.settings[:providers][:openai][:api_key]).to eq(env_default)
      end
    end

    context 'when the token has no exp claim' do
      let(:token_payload) { Base64.urlsafe_encode64({ sub: 'user123' }.to_json).delete('=') }
      let(:token) { "eyJhbGciOiJSUzI1NiJ9.#{token_payload}.signature" }
      let(:auth_json) do
        { auth_mode: 'chatgpt', tokens: { access_token: token } }.to_json
      end

      before do
        allow(File).to receive(:exist?).with(auth_path).and_return(true)
        allow(File).to receive(:read).with(auth_path).and_return(auth_json)
        stub_const('ENV', ENV.to_h.except('OPENAI_API_KEY', 'CODEX_API_KEY'))
      end

      it 'treats the token as valid' do
        described_class.load
        expect(Legion::LLM.settings[:providers][:openai][:api_key]).to eq(token)
      end
    end

    context 'when the token is not a JWT' do
      let(:auth_json) do
        { auth_mode: 'chatgpt', tokens: { access_token: 'plain-api-key' } }.to_json
      end

      before do
        allow(File).to receive(:exist?).with(auth_path).and_return(true)
        allow(File).to receive(:read).with(auth_path).and_return(auth_json)
        stub_const('ENV', ENV.to_h.except('OPENAI_API_KEY', 'CODEX_API_KEY'))
      end

      it 'accepts the token without validation' do
        described_class.load
        expect(Legion::LLM.settings[:providers][:openai][:api_key]).to eq('plain-api-key')
      end
    end

    context 'when auth file contains invalid JSON' do
      before do
        allow(File).to receive(:exist?).with(auth_path).and_return(true)
        allow(File).to receive(:read).with(auth_path).and_return('not json')
      end

      it 'returns nil without error' do
        expect(described_class.load).to be_nil
        expect(Legion::LLM.settings[:providers][:openai][:api_key]).to eq(env_default)
      end
    end

    context 'when tokens.access_token is nil' do
      let(:auth_json) { { auth_mode: 'chatgpt', tokens: { access_token: nil } }.to_json }

      before do
        allow(File).to receive(:exist?).with(auth_path).and_return(true)
        allow(File).to receive(:read).with(auth_path).and_return(auth_json)
      end

      it 'does not import anything' do
        described_class.load
        expect(Legion::LLM.settings[:providers][:openai][:api_key]).to eq(env_default)
      end
    end
  end

  describe '.resolve_env_api_key' do
    it 'returns nil for nil' do
      expect(described_class.resolve_env_api_key(nil)).to be_nil
    end

    it 'returns nil for an empty string' do
      expect(described_class.resolve_env_api_key('')).to be_nil
    end

    it 'returns the string unchanged when not an env:// placeholder' do
      expect(described_class.resolve_env_api_key('sk-real')).to eq('sk-real')
    end

    it 'resolves an env:// placeholder to the ENV value' do
      stub_const('ENV', ENV.to_h.merge('TEST_KEY_XYZ' => 'resolved-value'))
      expect(described_class.resolve_env_api_key('env://TEST_KEY_XYZ')).to eq('resolved-value')
    end

    it 'returns nil when env:// placeholder points to an unset ENV var' do
      stub_const('ENV', ENV.to_h.except('MISSING_KEY_XYZ'))
      expect(described_class.resolve_env_api_key('env://MISSING_KEY_XYZ')).to be_nil
    end

    it 'returns nil for an array of unresolvable env:// placeholders' do
      stub_const('ENV', {})
      expect(described_class.resolve_env_api_key(['env://A', 'env://B'])).to be_nil
    end

    it 'returns the first resolved value from an array' do
      stub_const('ENV', ENV.to_h.merge('KEY_A' => 'val-a'))
      expect(described_class.resolve_env_api_key(['env://KEY_A', 'env://KEY_B'])).to eq('val-a')
    end

    it 'passes through non-string, non-array values unchanged' do
      expect(described_class.resolve_env_api_key(42)).to eq(42)
    end
  end

  describe '.token_valid?' do
    it 'returns true for non-JWT tokens' do
      expect(described_class.token_valid?('plain-key')).to be true
    end

    it 'returns true for tokens with future exp' do
      payload = Base64.urlsafe_encode64({ exp: Time.now.to_i + 3600 }.to_json).delete('=')
      token = "header.#{payload}.sig"
      expect(described_class.token_valid?(token)).to be true
    end

    it 'returns false for tokens with past exp' do
      payload = Base64.urlsafe_encode64({ exp: Time.now.to_i - 3600 }.to_json).delete('=')
      token = "header.#{payload}.sig"
      expect(described_class.token_valid?(token)).to be false
    end

    it 'returns true and emits debug exception logging when base64/JSON parsing fails' do
      # payload part is not valid base64-encoded JSON
      token = 'header.!!!invalid!!!.sig'
      expect(Legion::Logging).to receive(:debug).with(/invalid base64/).at_least(:once)
      expect(described_class.token_valid?(token)).to be true
    end
  end
end
