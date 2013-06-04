require 'spec_helper'

describe 'aws-ha-release' do
  let(:opts) do
    {
      as_group_name: 'test_group',
      aws_access_key: 'testaccesskey',
      aws_secret_key: 'testsecretkey',
      region: 'test-region',
      inservice_time_allowed: 300,
      elb_timeout: 0
    }
  end

  let(:as) { AWS::FakeAutoScaling.new }

  before do
    AWS::AutoScaling.stub(:new).and_return(as)
    IO.any_instance.stub(:puts)
  end

  describe '#initialize' do
    it 'initializes the AWS connection' do
      as.groups.create opts[:as_group_name]

      AWS.should_receive(:config).with(access_key_id: 'testaccesskey', secret_access_key: 'testsecretkey', region: 'test-region')
      AwsHaRelease.new(opts)
    end

    it 'ensures the as group exists' do
      lambda {
        AwsHaRelease.new(opts.merge!(as_group_name: 'fake_group'))
      }.should raise_error
    end
  end

  describe '#execute!' do
    before do
      @group = as.groups.create opts[:as_group_name]
      @aws_ha_release = AwsHaRelease.new(opts)
    end

    it 'suspends certain autoscaling processes' do
      AWS::FakeAutoScaling::Group.any_instance.should_receive(:suspend_processes)
          .with(%w(ReplaceUnhealthy AlarmNotification ScheduledActions AZRebalance))
      @aws_ha_release.execute!
    end

    it 'requires certain autoscaling processes to not be suspended' do
      @aws_ha_release.group.suspend_processes %w(RemoveFromLoadBalancerLowPriority Terminate Launch HealthCheck AddToLoadBalancer)
      expect{ @aws_ha_release.execute! }.to raise_error
    end

    it 'adjusts the max size as well as the desired capacity if the desired capacity is equal to it' do
      @group.update(max_size: 1, desired_capacity: 1)

      @aws_ha_release.group.should_receive(:update).with(max_size: 2).ordered.and_call_original
      @aws_ha_release.group.should_receive(:update).with(desired_capacity: 2).ordered.and_call_original
      @aws_ha_release.group.should_receive(:update).with(desired_capacity: 1).ordered.and_call_original
      @aws_ha_release.group.should_receive(:update).with(max_size: 1).ordered.and_call_original
      @aws_ha_release.execute!
    end

    it 'only adjusts the desired capacity if max size does not equal desired capacity' do
      @aws_ha_release.group.should_receive(:update).with(desired_capacity: 2).ordered.and_call_original
      @aws_ha_release.group.should_receive(:update).with(desired_capacity: 1).ordered.and_call_original
      @aws_ha_release.execute!
    end
  end

  describe 'determining if instances are in service' do
    before do
      @group = as.groups.create opts[:as_group_name]
      @aws_ha_release = AwsHaRelease.new(opts)
    end

    it 'checks all instances across a given load balancer' do
      load_balancer = AWS::FakeELB::LoadBalancer.new 'test_load_balancer_01'

      expect(@aws_ha_release.instances_inservice?(load_balancer)).to eq false

      load_balancer.instances.health[1] = {
        instance: AWS::FakeEC2::Instance.new,
        description: 'N/A',
        state: 'InService',
        reason_code: 'N/A'
      }

      expect(@aws_ha_release.instances_inservice?(load_balancer)).to eq true
    end

    it 'checks all instances across an array of load balancers' do
      load_balancers = [AWS::FakeELB::LoadBalancer.new('test_load_balancer_01'), AWS::FakeELB::LoadBalancer.new('test_load_balancer_02')]

      expect(@aws_ha_release.all_instances_inservice?(load_balancers)).to eq false

      load_balancers[0].instances.health[1] = {
        instance: AWS::FakeEC2::Instance.new,
        description: 'N/A',
        state: 'InService',
        reason_code: 'N/A'
      }

      expect(@aws_ha_release.all_instances_inservice?(load_balancers)).to eq false

      load_balancers[1].instances.health[1] = {
        instance: AWS::FakeEC2::Instance.new,
        description: 'N/A',
        state: 'InService',
        reason_code: 'N/A'
      }

      expect(@aws_ha_release.all_instances_inservice?(load_balancers)).to eq true
    end
  end

  describe '#deregister_instance' do
    before do
      @group = as.groups.create opts[:as_group_name]
      @aws_ha_release = AwsHaRelease.new(opts)
    end

    it 'deregisters an instance across all load balancers' do
      instance_one = AWS::FakeEC2::Instance.new
      instance_two = AWS::FakeEC2::Instance.new

      elb_one = AWS::FakeELB::LoadBalancer.new 'test_load_balancer_01'
      elb_two = AWS::FakeELB::LoadBalancer.new 'test_load_balancer_02'

      elb_one.instances.register instance_one
      elb_one.instances.register instance_two

      elb_two.instances.register instance_one
      elb_two.instances.register instance_two

      @aws_ha_release.deregister_instance instance_one, [elb_one, elb_two]

      expect(elb_one.instances).not_to include instance_one
      expect(elb_two.instances).not_to include instance_one
    end
  end
end
