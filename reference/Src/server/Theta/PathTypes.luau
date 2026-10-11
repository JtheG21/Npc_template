--!strict
-- PathTypes: shared types and the binary min-heap used by the Theta* solver.
local PathTypes = {}

export type Node = {
	Position: Vector3,
	Walkable: boolean,
	G: number,
	H: number,
	F: number,
	Parent: Node?,
	GridX: number,
	GridZ: number,
}



export type Grid = { [number]: { [number]: Node } }

-- Min-heap ordered by Node.F, so the solver always pops the cheapest open node.
local MinHeap = {}
MinHeap.__index = MinHeap

export type MinHeap = typeof(setmetatable({} :: { heap: { Node } }, MinHeap))

function PathTypes.newMinHeap(): MinHeap
	return setmetatable({ heap = {} }, MinHeap)
end

function MinHeap.Insert(self: MinHeap, node: Node)
	table.insert(self.heap, node)
	local index = #self.heap

	-- Sift up: bubble the new node past ancestors with a higher F cost.
	while index > 1 do
		local parentIndex = math.floor(index / 2)
		if self.heap[index].F >= self.heap[parentIndex].F then break end
		self.heap[index], self.heap[parentIndex] = self.heap[parentIndex], self.heap[index]
		index = parentIndex
	end
end

function MinHeap.Pop(self: MinHeap): Node?
	local size = #self.heap
	if size == 0 then return nil end

	local root = self.heap[1]
	self.heap[1] = self.heap[size]
	table.remove(self.heap, size)
	size -= 1

	-- Sift down: move the swapped-in node past its cheaper children.
	local index = 1
	while true do
		local leftChild = index * 2
		local rightChild = index * 2 + 1
		local smallest = index

		if leftChild <= size and self.heap[leftChild].F < self.heap[smallest].F then
			smallest = leftChild
		end
		
		if rightChild <= size and self.heap[rightChild].F < self.heap[smallest].F then
			smallest = rightChild
		end
		
		if smallest == index then break end

		self.heap[index], self.heap[smallest] = self.heap[smallest], self.heap[index]
		index = smallest
	end

	return root
end

function MinHeap.IsEmpty(self: MinHeap): boolean
	return #self.heap == 0
end

return PathTypes
