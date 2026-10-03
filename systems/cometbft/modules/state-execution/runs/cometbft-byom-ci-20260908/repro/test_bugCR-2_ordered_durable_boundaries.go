package consensus_test

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	dbm "github.com/cometbft/cometbft-db"
	"github.com/cometbft/cometbft/abci/example/kvstore"
	abci "github.com/cometbft/cometbft/abci/types"
	cmtproto "github.com/cometbft/cometbft/api/cometbft/types/v1"
	cfg "github.com/cometbft/cometbft/config"
	sm "github.com/cometbft/cometbft/internal/state"
	storepkg "github.com/cometbft/cometbft/internal/store"
	testutil "github.com/cometbft/cometbft/internal/test"
	"github.com/cometbft/cometbft/libs/log"
	"github.com/cometbft/cometbft/node"
	"github.com/cometbft/cometbft/p2p"
	"github.com/cometbft/cometbft/privval"
	"github.com/cometbft/cometbft/proxy"
	rpclocal "github.com/cometbft/cometbft/rpc/client/local"
)

const updatedMaxBytes int64 = 20_000_000

// paramUpdateApp uses the normal persistent example application and returns a
// valid consensus-parameter update at height 1. The embedded application keeps
// the normal FinalizeBlock/Commit persistence contract.
type paramUpdateApp struct {
	*kvstore.Application
}

func (app *paramUpdateApp) FinalizeBlock(ctx context.Context, req *abci.FinalizeBlockRequest) (*abci.FinalizeBlockResponse, error) {
	resp, err := app.Application.FinalizeBlock(ctx, req)
	if err != nil {
		return nil, err
	}
	if req.Height == 1 {
		resp.ConsensusParamUpdates = &cmtproto.ConsensusParams{
			Block: &cmtproto.BlockParams{MaxBytes: updatedMaxBytes, MaxGas: -1},
		}
	}
	return resp, nil
}

func testConfig(root string) *cfg.Config {
	c := cfg.TestConfig()
	c.DBBackend = string(dbm.GoLevelDBBackend)
	c.RPC.ListenAddress = ""
	c.GRPC.ListenAddress = ""
	c.GRPC.Privileged.ListenAddress = ""
	c.P2P.ListenAddress = "tcp://127.0.0.1:0"
	c.P2P.PexReactor = false
	c.Instrumentation.Prometheus = false
	return c.SetRoot(root)
}

func openNode(root string) (*node.Node, *paramUpdateApp, error) {
	c := testConfig(root)
	nodeKey, err := p2p.LoadOrGenNodeKey(c.NodeKeyFile())
	if err != nil {
		return nil, nil, err
	}
	app := &paramUpdateApp{Application: kvstore.NewPersistentApplication(filepath.Join(root, "app"))}
	n, err := node.NewNode(
		context.Background(),
		c,
		privval.LoadOrGenFilePV(c.PrivValidatorKeyFile(), c.PrivValidatorStateFile()),
		nodeKey,
		proxy.NewLocalClientCreator(app),
		node.DefaultGenesisDocProviderFunc(c),
		cfg.DefaultDBProvider,
		node.DefaultMetricsProvider(c.Instrumentation),
		log.NewNopLogger(),
	)
	if err != nil {
		_ = app.Close()
		return nil, nil, err
	}
	return n, app, nil
}

func closeNode(n *node.Node, app *paramUpdateApp) {
	if n.IsRunning() {
		_ = n.Stop()
		n.Wait()
	}
	_ = n.ProxyApp().Stop()
	_ = app.Close()
}

func waitForAndCheckPublicConsumers(n *node.Node, label string) error {
	client := rpclocal.New(n)
	deadline := time.Now().Add(15 * time.Second)
	var nodeHeight int64
	for time.Now().Before(deadline) {
		status, err := client.Status(context.Background())
		if err == nil {
			nodeHeight = status.SyncInfo.LatestBlockHeight
			if nodeHeight >= 2 {
				break
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	if nodeHeight < 2 {
		return fmt.Errorf("node did not reach height 2 (latest %d)", nodeHeight)
	}

	height1, height2 := int64(1), int64(2)
	results, err := client.BlockResults(context.Background(), &height1)
	if err != nil {
		return fmt.Errorf("BlockResults(1): %w", err)
	}
	if results.ConsensusParamUpdates == nil || results.ConsensusParamUpdates.Block == nil {
		return fmt.Errorf("BlockResults(1) lost consensus parameter update")
	}
	params, err := client.ConsensusParams(context.Background(), &height2)
	if err != nil {
		return fmt.Errorf("ConsensusParams(2): %w", err)
	}
	if got := params.ConsensusParams.Block.MaxBytes; got != updatedMaxBytes {
		return fmt.Errorf("ConsensusParams(2).Block.MaxBytes=%d, want %d", got, updatedMaxBytes)
	}
	appInfo, err := client.ABCIInfo(context.Background())
	if err != nil {
		return fmt.Errorf("ABCIInfo: %w", err)
	}
	fmt.Printf("%s node_height=%d app_height=%d results_h1_max_bytes=%d params_h2_max_bytes=%d\n",
		label,
		nodeHeight,
		appInfo.Response.LastBlockHeight,
		results.ConsensusParamUpdates.Block.MaxBytes,
		params.ConsensusParams.Block.MaxBytes,
	)
	return nil
}

func runHelper(t *testing.T) {
	root := os.Getenv("CR2_ROOT")
	mode := os.Getenv("CR2_MODE")
	if root == "" || mode == "" {
		t.Fatal("CR2_ROOT and CR2_MODE are required")
	}
	n, app, err := openNode(root)
	if err != nil {
		t.Fatalf("open node: %v", err)
	}
	defer closeNode(n, app)
	if err := n.Start(); err != nil {
		t.Fatalf("start node: %v", err)
	}
	if mode == "fault" {
		deadline := time.Now().Add(15 * time.Second)
		for time.Now().Before(deadline) {
			if n.BlockStore().Height() >= 2 {
				t.Fatalf("configured fail point did not stop first-height processing")
			}
			time.Sleep(20 * time.Millisecond)
		}
		t.Fatal("configured fail point did not execute")
	}
	if err := waitForAndCheckPublicConsumers(n, strings.ToUpper(mode)); err != nil {
		t.Fatal(err)
	}
}

type durableSnapshot struct {
	blockHeight int64
	stateHeight int64
	appHeight   int64
	responseH1  bool
	paramsH2    bool
}

func inspectDurableSnapshot(root string) (durableSnapshot, error) {
	c := testConfig(root)
	blockDB, err := cfg.DefaultDBProvider(&cfg.DBContext{ID: "blockstore", Config: c})
	if err != nil {
		return durableSnapshot{}, err
	}
	blockStore := storepkg.NewBlockStore(blockDB)
	defer blockStore.Close()

	stateDB, err := cfg.DefaultDBProvider(&cfg.DBContext{ID: "state", Config: c})
	if err != nil {
		return durableSnapshot{}, err
	}
	stateStore := sm.NewStore(stateDB, sm.StoreOptions{DiscardABCIResponses: false})
	defer stateStore.Close()
	state, err := stateStore.Load()
	if err != nil {
		return durableSnapshot{}, err
	}
	_, responseErr := stateStore.LoadLastFinalizeBlockResponse(1)
	_, paramsErr := stateStore.LoadConsensusParams(2)

	app := kvstore.NewPersistentApplication(filepath.Join(root, "app"))
	info, err := app.Info(context.Background(), &abci.InfoRequest{})
	closeErr := app.Close()
	if err != nil {
		return durableSnapshot{}, err
	}
	if closeErr != nil {
		return durableSnapshot{}, closeErr
	}
	return durableSnapshot{
		blockHeight: blockStore.Height(),
		stateHeight: state.LastBlockHeight,
		appHeight:   info.LastBlockHeight,
		responseH1:  responseErr == nil,
		paramsH2:    paramsErr == nil,
	}, nil
}

func runChild(root, mode string, failIndex *int) ([]byte, error) {
	cmd := exec.Command(os.Args[0], "-test.run=^TestBugCR2OrderedDurableBoundaries$", "-test.v")
	env := append(os.Environ(), "CR2_HELPER=1", "CR2_ROOT="+root, "CR2_MODE="+mode)
	if failIndex != nil {
		env = append(env, "FAIL_TEST_INDEX="+strconv.Itoa(*failIndex))
	} else {
		filtered := env[:0]
		for _, item := range env {
			if !strings.HasPrefix(item, "FAIL_TEST_INDEX=") {
				filtered = append(filtered, item)
			}
		}
		env = filtered
	}
	cmd.Env = env
	return cmd.CombinedOutput()
}

func extractEvidence(out []byte) string {
	for _, line := range strings.Split(string(out), "\n") {
		if strings.Contains(line, "*** fail-test") || strings.HasPrefix(line, "BASELINE ") || strings.HasPrefix(line, "RECOVER ") {
			return line
		}
	}
	return strings.TrimSpace(string(out))
}

func copyTree(src, dst string) error {
	return filepath.WalkDir(src, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		target := filepath.Join(dst, rel)
		info, err := d.Info()
		if err != nil {
			return err
		}
		if d.IsDir() {
			return os.MkdirAll(target, info.Mode())
		}
		in, err := os.Open(path)
		if err != nil {
			return err
		}
		defer in.Close()
		out, err := os.OpenFile(target, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, info.Mode())
		if err != nil {
			return err
		}
		_, copyErr := io.Copy(out, in)
		closeErr := out.Close()
		if copyErr != nil {
			return copyErr
		}
		return closeErr
	})
}

func TestBugCR2OrderedDurableBoundaries(t *testing.T) {
	if os.Getenv("CR2_HELPER") != "" {
		runHelper(t)
		return
	}

	// Level 0: normal node operation, without timing control.
	baselineRoot := testutil.ResetTestRoot("cr2_level0")
	defer os.RemoveAll(baselineRoot.RootDir)
	out, err := runChild(baselineRoot.RootDir, "baseline", nil)
	if err != nil {
		t.Fatalf("level 0 failed: %v\n%s", err, out)
	}
	fmt.Printf("LEVEL0 %s\n", extractEvidence(out))

	// Level 1: the source-provided fail hook stops at every ordered boundary.
	// Indices 3..8 correspond respectively to: saved block; synced WAL marker;
	// returned FinalizeBlock; saved response; committed app; saved CometBFT state.
	for _, index := range []int{3, 4, 5, 6, 7, 8} {
		root := testutil.ResetTestRoot(fmt.Sprintf("cr2_level1_%d", index))
		faultOut, faultErr := runChild(root.RootDir, "fault", &index)
		if faultErr == nil || !bytes.Contains(faultOut, []byte(fmt.Sprintf("*** fail-test %d ***", index))) {
			os.RemoveAll(root.RootDir)
			t.Fatalf("level 1 index %d did not execute expected fail hook: err=%v\n%s", index, faultErr, faultOut)
		}
		snapshot, err := inspectDurableSnapshot(root.RootDir)
		if err != nil {
			os.RemoveAll(root.RootDir)
			t.Fatalf("inspect index %d: %v", index, err)
		}
		fmt.Printf("LEVEL1 index=%d block=%d state=%d app=%d response_h1=%t params_h2=%t marker=%q\n",
			index, snapshot.blockHeight, snapshot.stateHeight, snapshot.appHeight,
			snapshot.responseH1, snapshot.paramsH2, extractEvidence(faultOut))

		// Level 2: preserve the naturally reached on-disk precondition and replay
		// it through the real node constructor. This is not a fabricated state.
		if index == 7 {
			snapshotRoot, err := os.MkdirTemp("", "cr2_level2_reachable_snapshot_")
			if err != nil {
				t.Fatal(err)
			}
			defer os.RemoveAll(snapshotRoot)
			if err := copyTree(root.RootDir, snapshotRoot); err != nil {
				t.Fatalf("copy reachable snapshot: %v", err)
			}
			snapshotOut, err := runChild(snapshotRoot, "recover", nil)
			if err != nil {
				t.Fatalf("level 2 reachable snapshot recovery: %v\n%s", err, snapshotOut)
			}
			fmt.Printf("LEVEL2 reachable_sequence=NewNode->consensus_height_1->FinalizeBlock->SaveFinalizeBlockResponse->Commit->fail_hook %s\n", extractEvidence(snapshotOut))
		}

		recoverOut, err := runChild(root.RootDir, "recover", nil)
		os.RemoveAll(root.RootDir)
		if err != nil {
			t.Fatalf("recover index %d: %v\n%s", index, err, recoverOut)
		}
		fmt.Printf("LEVEL1 index=%d %s\n", index, extractEvidence(recoverOut))
	}

	// Level 3 adds no distinct state: the built-in hook already runs at the
	// exact post-operation boundaries where a delay would be inserted. A source
	// delay was therefore intentionally not added; it cannot exceed Level 1's
	// boundary precision and would only duplicate the same reachable snapshots.
	fmt.Println("LEVEL3 not-applied: exact source-provided boundary hooks already dominate delay-only timing assistance")
	fmt.Println("RESULT no wrong public outcome observed; all reachable boundary snapshots recovered the height-1 response and height-2 consensus parameters")
}
