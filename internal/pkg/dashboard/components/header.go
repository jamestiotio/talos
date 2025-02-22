// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

package components

import (
	"fmt"
	"math"
	"time"

	"github.com/dustin/go-humanize"
	"github.com/rivo/tview"

	"github.com/siderolabs/talos/internal/pkg/dashboard/apidata"
	"github.com/siderolabs/talos/internal/pkg/dashboard/resourcedata"
	"github.com/siderolabs/talos/pkg/machinery/resources/network"
)

const noHostname = "(no hostname)"

type headerData struct {
	hostname        string
	version         string
	uptime          string
	numCPUs         string
	cpuFreq         string
	totalMem        string
	numProcesses    string
	cpuUsagePercent string
	memUsagePercent string
}

// Header represents the top bar with host info.
type Header struct {
	tview.TextView

	selectedNode string
	nodeMap      map[string]*headerData
}

// NewHeader initializes Header.
func NewHeader() *Header {
	header := &Header{
		TextView: *tview.NewTextView(),
		nodeMap:  make(map[string]*headerData),
	}

	header.SetDynamicColors(true).SetText(noData)

	return header
}

// OnNodeSelect implements the NodeSelectListener interface.
func (widget *Header) OnNodeSelect(node string) {
	if node != widget.selectedNode {
		widget.selectedNode = node

		widget.redraw()
	}
}

// OnResourceDataChange implements the ResourceDataListener interface.
func (widget *Header) OnResourceDataChange(data resourcedata.Data) {
	nodeData := widget.getOrCreateNodeData(data.Node)

	switch res := data.Resource.(type) { //nolint:gocritic
	case *network.HostnameStatus:
		if data.Deleted {
			nodeData.hostname = noHostname
		} else {
			nodeData.hostname = res.TypedSpec().Hostname
		}
	}

	if data.Node == widget.selectedNode {
		widget.redraw()
	}
}

// OnAPIDataChange implements the APIDataListener interface.
func (widget *Header) OnAPIDataChange(node string, data *apidata.Data) {
	nodeAPIData := data.Nodes[node]

	widget.updateNodeAPIData(node, nodeAPIData)

	if node == widget.selectedNode {
		widget.redraw()
	}
}

func (widget *Header) humanizeCPUFrequency(mhz float64) string {
	value := math.Round(mhz)
	unit := "MHz"

	if mhz >= 1000 {
		ghz := value / 1000
		value = math.Round(ghz*100) / 100
		unit = "GHz"
	}

	return fmt.Sprintf("%s%s", humanize.Ftoa(value), unit)
}

func (widget *Header) redraw() {
	data := widget.getOrCreateNodeData(widget.selectedNode)

	text := fmt.Sprintf(
		"[yellow::b]%s[-:-:-] (%s): uptime %s, %sx%s, %s RAM, PROCS %s, CPU %s, RAM %s",
		data.hostname,
		data.version,
		data.uptime,
		data.numCPUs,
		data.cpuFreq,
		data.totalMem,
		data.numProcesses,
		data.cpuUsagePercent,
		data.memUsagePercent,
	)

	widget.SetText(text)
}

func (widget *Header) updateNodeAPIData(node string, data *apidata.Node) {
	sss := widget.getOrCreateNodeData(node)

	if data == nil {
		return
	}

	sss.cpuUsagePercent = fmt.Sprintf("%.1f%%", data.CPUUsageByName("usage")*100.0)
	sss.memUsagePercent = fmt.Sprintf("%.1f%%", data.MemUsage()*100.0)

	if data.Hostname != nil {
		sss.hostname = data.Hostname.GetHostname()
	}

	if data.Version != nil {
		sss.version = data.Version.GetVersion().GetTag()
	}

	if data.SystemStat != nil {
		sss.uptime = time.Since(time.Unix(int64(data.SystemStat.GetBootTime()), 0)).Round(time.Second).String()
	}

	if data.CPUsInfo != nil {
		sss.numCPUs = fmt.Sprintf("%d", len(data.CPUsInfo.GetCpuInfo()))
		sss.cpuFreq = widget.humanizeCPUFrequency(data.CPUsInfo.GetCpuInfo()[0].GetCpuMhz())
	}

	if data.Processes != nil {
		sss.numProcesses = fmt.Sprintf("%d", len(data.Processes.GetProcesses()))
	}

	if data.Memory != nil {
		sss.totalMem = humanize.IBytes(data.Memory.GetMeminfo().GetMemtotal() << 10)
	}
}

func (widget *Header) getOrCreateNodeData(node string) *headerData {
	data, ok := widget.nodeMap[node]
	if !ok {
		data = &headerData{
			hostname:        notAvailable,
			version:         notAvailable,
			uptime:          notAvailable,
			numCPUs:         notAvailable,
			cpuFreq:         notAvailable,
			totalMem:        notAvailable,
			numProcesses:    notAvailable,
			cpuUsagePercent: notAvailable,
			memUsagePercent: notAvailable,
		}

		widget.nodeMap[node] = data
	}

	return data
}
