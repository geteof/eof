// One generation of Conway's Game of Life on a board that wraps around.
export type Board = Uint8Array

export function step(cells: Board, size: number): Board {
  const next = new Uint8Array(cells.length)
  for (let i = 0; i < cells.length; i++) {
    const x = i % size, y = Math.floor(i / size)
    let neighbours = 0
    for (let dy = -1; dy <= 1; dy++)
      for (let dx = -1; dx <= 1; dx++)
        if (dx || dy) neighbours += cells[wrap(y + dy, size) * size + wrap(x + dx, size)]
    next[i] = neighbours === 3 || (cells[i] && neighbours === 2) ? 1 : 0
  }
  return next
}

const wrap = (n: number, size: number) => (n + size) % size
