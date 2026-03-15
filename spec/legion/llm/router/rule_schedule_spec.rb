# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router/resolution'
require 'legion/llm/router/rule'

RSpec.describe Legion::LLM::Router::Rule do
  def build_rule(schedule)
    described_class.from_hash(
      name: :sched_rule,
      when: {},
      then: { tier: :cloud, provider: :anthropic, model: 'claude-sonnet-4-6' },
      schedule: schedule
    )
  end

  describe '#within_schedule?' do
    context 'when no schedule is set' do
      it 'returns true when schedule is nil' do
        rule = build_rule(nil)
        expect(rule.within_schedule?).to be true
      end

      it 'returns true when schedule is an empty hash' do
        rule = build_rule({})
        expect(rule.within_schedule?).to be true
      end
    end

    context 'valid_from / valid_until boundaries' do
      let(:now) { Time.now }

      it 'returns true when now is within valid_from and valid_until' do
        schedule = {
          'valid_from'  => (now - 3600).iso8601,
          'valid_until' => (now + 3600).iso8601
        }
        rule = build_rule(schedule)
        expect(rule.within_schedule?(now)).to be true
      end

      it 'returns false when now is before valid_from' do
        schedule = { 'valid_from' => (now + 3600).iso8601 }
        rule = build_rule(schedule)
        expect(rule.within_schedule?(now)).to be false
      end

      it 'returns false when now is after valid_until' do
        schedule = { 'valid_until' => (now - 3600).iso8601 }
        rule = build_rule(schedule)
        expect(rule.within_schedule?(now)).to be false
      end

      it 'returns true when only valid_from is set and now is past it' do
        schedule = { 'valid_from' => (now - 3600).iso8601 }
        rule = build_rule(schedule)
        expect(rule.within_schedule?(now)).to be true
      end

      it 'returns true when only valid_until is set and now is before it' do
        schedule = { 'valid_until' => (now + 3600).iso8601 }
        rule = build_rule(schedule)
        expect(rule.within_schedule?(now)).to be true
      end
    end

    context 'hours ranges' do
      let(:now) { Time.now }
      let(:current_minutes) { now.hour * 60 + now.min }

      it 'returns true when the current time is within a listed hours range' do
        # Build a range that definitely includes now: now-1h to now+1h, clamped to 0-1439
        start_min = [current_minutes - 60, 0].max
        end_min   = [current_minutes + 60, 1439].min
        start_str = format('%02d:%02d', start_min / 60, start_min % 60)
        end_str   = format('%02d:%02d', end_min / 60, end_min % 60)
        rule = build_rule({ 'hours' => ["#{start_str}-#{end_str}"] })
        expect(rule.within_schedule?(now)).to be true
      end

      it 'returns false when the current time is outside all listed hours ranges' do
        # Build a range that definitely excludes now (2 hours in the future, 1 hour wide)
        start_min = (current_minutes + 120) % 1440
        end_min   = (current_minutes + 180) % 1440
        # Only safe to use this approach when the range does not wrap midnight and is not huge
        # Recalculate without modulo to ensure a clean non-wrapping forward window
        if current_minutes + 180 <= 1439
          start_str = format('%02d:%02d', start_min / 60, start_min % 60)
          end_str   = format('%02d:%02d', end_min / 60, end_min % 60)
          rule = build_rule({ 'hours' => ["#{start_str}-#{end_str}"] })
          expect(rule.within_schedule?(now)).to be false
        else
          # Near midnight: use a morning window that cannot include midnight-adjacent times
          rule = build_rule({ 'hours' => ['02:00-03:00'] })
          adjusted_now = Time.new(now.year, now.month, now.day, 14, 0, 0)
          expect(rule.within_schedule?(adjusted_now)).to be false
        end
      end
    end

    context 'days of week' do
      let(:now) { Time.now }
      let(:today_name) { now.strftime('%A').downcase }

      let(:all_days) { %w[monday tuesday wednesday thursday friday saturday sunday] }

      it 'returns true when today matches the days list' do
        rule = build_rule({ 'days' => [today_name] })
        expect(rule.within_schedule?(now)).to be true
      end

      it 'returns false when today does not match the days list' do
        other_days = all_days - [today_name]
        rule = build_rule({ 'days' => other_days })
        expect(rule.within_schedule?(now)).to be false
      end
    end

    context 'combined schedule conditions (AND logic)' do
      let(:now) { Time.now }
      let(:today_name) { now.strftime('%A').downcase }
      let(:current_minutes) { now.hour * 60 + now.min }

      it 'returns true only when all conditions match' do
        start_min = [current_minutes - 60, 0].max
        end_min   = [current_minutes + 60, 1439].min
        start_str = format('%02d:%02d', start_min / 60, start_min % 60)
        end_str   = format('%02d:%02d', end_min / 60, end_min % 60)

        schedule = {
          'valid_from'  => (now - 3600).iso8601,
          'valid_until' => (now + 3600).iso8601,
          'hours'       => ["#{start_str}-#{end_str}"],
          'days'        => [today_name]
        }
        rule = build_rule(schedule)
        expect(rule.within_schedule?(now)).to be true
      end

      it 'returns false when date is valid but day does not match' do
        all_days = %w[monday tuesday wednesday thursday friday saturday sunday]
        other_days = all_days - [today_name]

        schedule = {
          'valid_from' => (now - 3600).iso8601,
          'valid_until' => (now + 3600).iso8601,
          'days' => other_days
        }
        rule = build_rule(schedule)
        expect(rule.within_schedule?(now)).to be false
      end

      it 'returns false when day matches but date range has expired' do
        schedule = {
          'valid_until' => (now - 3600).iso8601,
          'days' => [today_name]
        }
        rule = build_rule(schedule)
        expect(rule.within_schedule?(now)).to be false
      end
    end

    context 'timezone key is stored but not used for conversion' do
      it 'does not raise when timezone is present' do
        now = Time.now
        schedule = {
          'valid_from' => (now - 3600).iso8601,
          'valid_until' => (now + 3600).iso8601,
          'timezone' => 'America/Chicago'
        }
        rule = build_rule(schedule)
        expect { rule.within_schedule?(now) }.not_to raise_error
        expect(rule.within_schedule?(now)).to be true
      end
    end
  end
end
