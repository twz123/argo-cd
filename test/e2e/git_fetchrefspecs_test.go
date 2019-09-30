package e2e

import (
	"testing"

	"github.com/argoproj/argo-cd/test/e2e/fixture"

	. "github.com/argoproj/argo-cd/pkg/apis/application/v1alpha1"
	. "github.com/argoproj/argo-cd/test/e2e/fixture/app"
)

func TestSyncFromGitRefspecs(t *testing.T) {
	Given(t).
		SSHRepoURLAdded().
		RepoURLType(fixture.RepoURLTypeSSH).
		Path("hidden-gem").
		Revision("hidden-gem").
		When().
		IgnoreErrors().
		Create().
		Then().
		Expect(Error("", "Unable to resolve 'hidden-gem' to a commit SHA")).
		Given().
		SSHRepoURLAdded("+refs/heads/master:refs/remotes/origin/master", "+refs/hidden/gem:refs/remotes/origin/hidden-gem").
		When().
		Create().
		Sync().
		Then().
		Expect(OperationPhaseIs(OperationSucceeded))
}
