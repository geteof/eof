-- Top customers
SELECT c.name, SUM(o.total) AS revenue
FROM customers c
JOIN orders o ON o.customer_id = c.id
WHERE o.created_at >= '2026-01-01' AND o.status <> 'void'
GROUP BY c.name
ORDER BY revenue DESC
LIMIT 10;
