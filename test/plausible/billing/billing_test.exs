defmodule Plausible.BillingTest do
  use Plausible.DataCase
  use Bamboo.Test, shared: true
  alias Plausible.Billing
  import Plausible.TestUtils

  describe "usage" do
    test "is 0 with no events" do
      user = insert(:user)

      assert Billing.usage(user) == 0
    end

    test "counts the total number of events" do
      user = insert(:user)
      insert(:site, domain: "test-site.com", members: [user])

      assert Billing.usage(user) == 3
    end
  end

  describe "last_two_billing_cycles" do
    test "billing on the 1st" do
      last_bill_date = ~D[2021-01-01]
      today = ~D[2021-01-02]

      user = insert(:user, subscription: build(:subscription, last_bill_date: last_bill_date))

      expected_cycles = {
        Date.range(~D[2020-11-01], ~D[2020-11-30]),
        Date.range(~D[2020-12-01], ~D[2020-12-31])
      }

      assert Billing.last_two_billing_cycles(user, today) == expected_cycles
    end

    test "in case of yearly billing, cycles are normalized as if they were paying monthly" do
      last_bill_date = ~D[2020-09-01]
      today = ~D[2021-02-02]

      user = insert(:user, subscription: build(:subscription, last_bill_date: last_bill_date))

      expected_cycles = {
        Date.range(~D[2020-12-01], ~D[2020-12-31]),
        Date.range(~D[2021-01-01], ~D[2021-01-31])
      }

      assert Billing.last_two_billing_cycles(user, today) == expected_cycles
    end
  end

  describe "last_two_billing_months_usage" do
    test "counts events from last two billing cycles" do
      last_bill_date = ~D[2021-01-01]
      today = ~D[2021-01-02]
      user = insert(:user, subscription: build(:subscription, last_bill_date: last_bill_date))
      site = insert(:site, members: [user])

      create_pageviews([
        %{domain: site.domain, timestamp: ~N[2021-01-01 00:00:00]},
        %{domain: site.domain, timestamp: ~N[2020-12-31 00:00:00]},
        %{domain: site.domain, timestamp: ~N[2020-11-01 00:00:00]},
        %{domain: site.domain, timestamp: ~N[2020-10-31 00:00:00]}
      ])

      assert Billing.last_two_billing_months_usage(user, today) == {1, 1}
    end

    test "gets event count from last month and this one" do
      user =
        insert(:user,
          subscription:
            build(:subscription, last_bill_date: Timex.today() |> Timex.shift(days: -1))
        )

      assert Billing.last_two_billing_months_usage(user) == {0, 0}
    end
  end

  describe "trial_days_left" do
    test "is 30 days for new signup" do
      user = insert(:user)

      assert Billing.trial_days_left(user) == 30
    end

    test "is based on trial_expiry_date" do
      user = insert(:user, trial_expiry_date: Timex.shift(Timex.now(), days: 1))

      assert Billing.trial_days_left(user) == 1
    end
  end

  describe "on_trial?" do
    test "is true with >= 0 trial days left" do
      user = insert(:user)

      assert Billing.on_trial?(user)
    end

    test "is false with < 0 trial days left" do
      user = insert(:user, trial_expiry_date: Timex.shift(Timex.now(), days: -1))

      refute Billing.on_trial?(user)
    end

    test "is false if user has subscription" do
      user = insert(:user, subscription: build(:subscription))

      refute Billing.on_trial?(user)
    end
  end

  describe "needs_to_upgrade?" do
    test "is false for a trial user" do
      user = insert(:user)
      user = Repo.preload(user, :subscription)

      refute Billing.needs_to_upgrade?(user)
    end

    test "is true for a user with an expired trial" do
      user = insert(:user, trial_expiry_date: Timex.shift(Timex.today(), days: -1))
      user = Repo.preload(user, :subscription)

      assert Billing.needs_to_upgrade?(user)
    end

    test "is false for a user with an expired trial but an active subscription" do
      user = insert(:user, trial_expiry_date: Timex.shift(Timex.today(), days: -1))
      insert(:subscription, user: user)
      user = Repo.preload(user, :subscription)

      refute Billing.needs_to_upgrade?(user)
    end

    test "is false for a user with a cancelled subscription IF the billing cycle isn't completed yet" do
      user = insert(:user, trial_expiry_date: Timex.shift(Timex.today(), days: -1))
      insert(:subscription, user: user, status: "deleted", next_bill_date: Timex.today())
      user = Repo.preload(user, :subscription)

      refute Billing.needs_to_upgrade?(user)
    end

    test "is true for a user with a cancelled subscription IF the billing cycle is complete" do
      user = insert(:user, trial_expiry_date: Timex.shift(Timex.today(), days: -1))

      insert(:subscription,
        user: user,
        status: "deleted",
        next_bill_date: Timex.shift(Timex.today(), days: -1)
      )

      user = Repo.preload(user, :subscription)

      assert Billing.needs_to_upgrade?(user)
    end

    test "is false for a deleted subscription if not next_bill_date specified" do
      user = insert(:user, trial_expiry_date: Timex.shift(Timex.today(), days: -1))
      insert(:subscription, user: user, status: "deleted", next_bill_date: nil)
      user = Repo.preload(user, :subscription)

      assert Billing.needs_to_upgrade?(user)
    end
  end

  @subscription_id "subscription-123"
  @plan_id "plan-123"

  describe "subscription_created" do
    test "creates a subscription" do
      user = insert(:user)

      Billing.subscription_created(%{
        "alert_name" => "subscription_created",
        "subscription_id" => @subscription_id,
        "subscription_plan_id" => @plan_id,
        "update_url" => "update_url.com",
        "cancel_url" => "cancel_url.com",
        "passthrough" => user.id,
        "status" => "active",
        "next_bill_date" => "2019-06-01",
        "unit_price" => "6.00"
      })

      subscription = Repo.get_by(Plausible.Billing.Subscription, user_id: user.id)
      assert subscription.paddle_subscription_id == @subscription_id
      assert subscription.next_bill_date == ~D[2019-06-01]
      assert subscription.next_bill_amount == "6.00"
    end

    test "create with email address" do
      user = insert(:user)

      Billing.subscription_created(%{
        "passthrough" => "",
        "email" => user.email,
        "alert_name" => "subscription_created",
        "subscription_id" => @subscription_id,
        "subscription_plan_id" => @plan_id,
        "update_url" => "update_url.com",
        "cancel_url" => "cancel_url.com",
        "status" => "active",
        "next_bill_date" => "2019-06-01",
        "unit_price" => "6.00"
      })

      subscription = Repo.get_by(Plausible.Billing.Subscription, user_id: user.id)
      assert subscription.paddle_subscription_id == @subscription_id
      assert subscription.next_bill_date == ~D[2019-06-01]
      assert subscription.next_bill_amount == "6.00"
    end
  end

  describe "subscription_updated" do
    test "updates an existing subscription" do
      user = insert(:user)
      subscription = insert(:subscription, user: user)

      Billing.subscription_updated(%{
        "alert_name" => "subscription_updated",
        "subscription_id" => subscription.paddle_subscription_id,
        "subscription_plan_id" => "new-plan-id",
        "update_url" => "update_url.com",
        "cancel_url" => "cancel_url.com",
        "passthrough" => user.id,
        "status" => "active",
        "next_bill_date" => "2019-06-01",
        "new_unit_price" => "12.00"
      })

      subscription = Repo.get_by(Plausible.Billing.Subscription, user_id: user.id)
      assert subscription.paddle_plan_id == "new-plan-id"
      assert subscription.next_bill_amount == "12.00"
    end
  end

  describe "subscription_cancelled" do
    test "sets the status to deleted" do
      user = insert(:user)
      subscription = insert(:subscription, status: "active", user: user)

      Billing.subscription_cancelled(%{
        "alert_name" => "subscription_cancelled",
        "subscription_id" => subscription.paddle_subscription_id,
        "status" => "deleted"
      })

      subscription = Repo.get_by(Plausible.Billing.Subscription, user_id: user.id)
      assert subscription.status == "deleted"
    end

    test "ignores if the subscription cannot be found" do
      res =
        Billing.subscription_cancelled(%{
          "alert_name" => "subscription_cancelled",
          "subscription_id" => "some_nonexistent_id",
          "status" => "deleted"
        })

      assert res == {:ok, nil}
    end

    test "sends an email to confirm cancellation" do
      user = insert(:user)
      subscription = insert(:subscription, status: "active", user: user)

      Billing.subscription_cancelled(%{
        "alert_name" => "subscription_cancelled",
        "subscription_id" => subscription.paddle_subscription_id,
        "status" => "deleted"
      })

      assert_email_delivered_with(
        subject: "Your Plausible Analytics subscription has been canceled"
      )
    end
  end

  describe "subscription_payment_succeeded" do
    test "sets the next bill amount and date, last bill date" do
      user = insert(:user)
      subscription = insert(:subscription, user: user)

      Billing.subscription_payment_succeeded(%{
        "alert_name" => "subscription_payment_succeeded",
        "subscription_id" => subscription.paddle_subscription_id
      })

      subscription = Repo.get_by(Plausible.Billing.Subscription, user_id: user.id)
      assert subscription.next_bill_date == ~D[2019-07-10]
      assert subscription.next_bill_amount == "6.00"
      assert subscription.last_bill_date == ~D[2019-06-10]
    end

    test "ignores if the subscription cannot be found" do
      res =
        Billing.subscription_payment_succeeded(%{
          "alert_name" => "subscription_payment_succeeded",
          "subscription_id" => "nonexistent_subscription_id",
          "next_bill_date" => Timex.shift(Timex.today(), days: 30),
          "unit_price" => "12.00"
        })

      assert res == {:ok, nil}
    end
  end

  describe "change_plan" do
    test "sets the next bill amount and date" do
      user = insert(:user)
      insert(:subscription, user: user)

      Billing.change_plan(user, "123123")

      subscription = Repo.get_by(Plausible.Billing.Subscription, user_id: user.id)
      assert subscription.paddle_plan_id == "123123"
      assert subscription.next_bill_date == ~D[2019-07-10]
      assert subscription.next_bill_amount == "6.00"
    end
  end
end
