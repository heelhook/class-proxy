require 'spec_helper'
require 'fixtures/classes'

describe ClassProxy do
  before :each do
    reset_databases
  end

  let (:klass) { UserDb }
  let (:model) { klass.new }
  let (:login) { "heelhook" }

  it { klass.should respond_to :primary_fetch }
  it { klass.should respond_to :fallback_fetch }
  it { klass.should respond_to :after_fallback_fetch }
  it { klass.should respond_to :fetch }

  context "lazy loading" do
    let (:user) { klass.new(username: login) }

    it "has a user with a username" do
      user.username.should_not be_nil
    end

    it "doesn't have a name when skipping proxing" do
      user.no_proxy_person_name.should be_nil
    end

    it "has a name when using the proxy" do
      user.person_name.should_not be_nil
    end
  end

  context "fetching" do
    let (:user) { klass.fetch(username: login) }
    let (:saved_user) { user.save.reload }

    it "finds a user" do
      user.should_not be_nil
    end

    it "sets defaults keys" do
      user.person_name.should_not be_nil
    end

    it "sets after_fallback_fetch keys" do
      user.username.should == login
    end

    it "uses fallback methods overwriters" do
      user.username_uppercase.should == login.upcase
    end

    it "lazy loads undefined attributes using proxy_methods" do
      user.public_repos.should_not be_nil
    end
  end

  context "with no fallback post processor" do
    let (:klass) { SimpleClass }
    let (:user) { klass.fetch(login: login)}

    it "finds someone" do
      user.class.should == klass
    end

    it "the user has the right login" do
      user.login.should == login
    end
  end

  context "explicitly skip existent fallback" do
    let (:user) { klass.fetch({username: login}, {skip_fallback: true})}

    it "doesn't find someone" do
      user.should be_nil
    end
  end

  context "with an invalid class definition" do
    it "errors when a class has wrong methods" do
      expect {
        load 'fixtures/class_with_wrong_methods'
        ClassWithWrongMethods
      }.to raise_error LoadError
    end
  end

  context "manually created with some fields and not others" do
    let (:klass) { SimpleClass }
    let (:user) do
      u = klass.new
      u.login = login
      u
    end

    it "has a login" do
      user.login.should == login
    end

    it "doesn't have a name loaded" do
      user.no_proxy_name.should be_nil
    end

    it "lazy loads the name when requested" do
      user.name.should_not be_nil
    end

    it "doesn't have a name loaded again" do
      user.name = 'my made up name'
      user.name.should == 'my made up name'
    end

    it "respects proxy_methods that mix default procs and customized procs" do
      user.uppercase_login.should == user.login.upcase
    end

    it "calls the last version of an overwritten proxy_method" do
      user.followers.should == 'second version'
    end
  end
end