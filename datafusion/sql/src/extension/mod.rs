use datafusion_common::{DFSchemaRef, Result, TableReference};
use datafusion_expr::logical_plan::UserDefinedLogicalNodeCore;
use datafusion_expr::{Expr, LogicalPlan};
use std::fmt;
use std::hash::{Hash, Hasher};

/// Extension node for MERGE statement
///
/// This stores all components of a MERGE statement for later transformation
/// into actual DML operations (typically in an optimizer pass).
#[derive(PartialEq, Eq)]
pub struct MergeIntoExtension {
    /// Target table reference
    pub table_name: TableReference,
    /// Target table schema
    pub table_schema: DFSchemaRef,
    /// Source data (can be table scan or subquery)
    pub source: LogicalPlan,
    /// Join condition (ON clause)
    pub on: Expr,
    /// MERGE actions with predicates (in order for first-match-wins semantics)
    pub actions: Vec<MergeAction>,
    /// Output schema (for EXPLAIN, etc.)
    pub schema: DFSchemaRef,
}

/// Represents a single WHEN clause action in a MERGE statement
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Hash)]
pub struct MergeAction {
    /// The type of action and its data
    pub kind: MergeActionKind,
    /// Optional predicate (AND clause in WHEN)
    pub predicate: Option<Expr>,
}

/// Type of MERGE action
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Hash)]
pub enum MergeActionKind {
    /// WHEN MATCHED THEN UPDATE SET assignments
    MatchedUpdate {
        /// Column assignments as (column_name, expression) pairs
        assignments: Vec<(String, Expr)>,
    },
    /// WHEN MATCHED THEN DELETE
    MatchedDelete,
    /// WHEN NOT MATCHED THEN INSERT
    NotMatchedInsert {
        /// Column names to insert into (empty = all columns in order)
        columns: Vec<String>,
        /// Values to insert (expressions evaluated from source)
        values: Vec<Expr>,
    },
}

impl fmt::Debug for MergeIntoExtension {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        self.fmt_for_explain(f)
    }
}

impl Hash for MergeIntoExtension {
    fn hash<H: Hasher>(&self, state: &mut H) {
        self.table_name.hash(state);
        self.source.hash(state);
        self.on.hash(state);
        self.actions.hash(state);
        // Schema is not hashed as it's derived from the plan structure
    }
}

impl PartialOrd for MergeIntoExtension {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        // Compare by table_name first, then source plan
        match self.table_name.partial_cmp(&other.table_name) {
            Some(std::cmp::Ordering::Equal) => {
                match self.source.partial_cmp(&other.source) {
                    Some(std::cmp::Ordering::Equal) => self.on.partial_cmp(&other.on),
                    other_cmp => other_cmp,
                }
            }
            other_cmp => other_cmp,
        }
    }
}

impl UserDefinedLogicalNodeCore for MergeIntoExtension {
    fn name(&self) -> &str {
        "MergeInto"
    }

    fn inputs(&self) -> Vec<&LogicalPlan> {
        vec![&self.source]
    }

    fn schema(&self) -> &DFSchemaRef {
        &self.schema
    }

    fn expressions(&self) -> Vec<Expr> {
        // Collect all expressions: ON condition + action predicates + assignments/values
        let mut exprs = vec![self.on.clone()];

        for action in &self.actions {
            // Add action predicate if present
            if let Some(pred) = &action.predicate {
                exprs.push(pred.clone());
            }

            // Add expressions from action kind
            match &action.kind {
                MergeActionKind::MatchedUpdate { assignments } => {
                    // Add all assignment value expressions
                    for (_col, expr) in assignments {
                        exprs.push(expr.clone());
                    }
                }
                MergeActionKind::MatchedDelete => {
                    // No expressions for DELETE
                }
                MergeActionKind::NotMatchedInsert { columns: _, values } => {
                    // Add all insert value expressions
                    for expr in values {
                        exprs.push(expr.clone());
                    }
                }
            }
        }

        exprs
    }

    fn fmt_for_explain(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "MergeInto: target={}", self.table_name)
    }

    fn with_exprs_and_inputs(
        &self,
        mut exprs: Vec<Expr>,
        mut inputs: Vec<LogicalPlan>,
    ) -> Result<Self> {
        assert_eq!(inputs.len(), 1, "MergeInto must have exactly 1 input (source)");

        // Reconstruct the node with new expressions and inputs
        // The first expression is the ON condition
        let on = exprs.remove(0);

        // Rebuild actions with new expressions
        let mut expr_idx = 0;
        let mut new_actions = Vec::new();

        for action in &self.actions {
            // Get predicate if present
            let predicate = if action.predicate.is_some() {
                let pred = exprs.get(expr_idx).cloned();
                expr_idx += 1;
                pred
            } else {
                None
            };

            // Rebuild action kind with new expressions
            let new_kind = match &action.kind {
                MergeActionKind::MatchedUpdate { assignments } => {
                    let new_assignments = assignments
                        .iter()
                        .map(|(col, _old_expr)| {
                            let new_expr = exprs.get(expr_idx).cloned()
                                .unwrap_or_else(|| _old_expr.clone());
                            expr_idx += 1;
                            (col.clone(), new_expr)
                        })
                        .collect();
                    MergeActionKind::MatchedUpdate {
                        assignments: new_assignments,
                    }
                }
                MergeActionKind::MatchedDelete => MergeActionKind::MatchedDelete,
                MergeActionKind::NotMatchedInsert { columns, values } => {
                    let new_values = values
                        .iter()
                        .map(|_old_expr| {
                            let new_expr = exprs.get(expr_idx).cloned()
                                .unwrap_or_else(|| _old_expr.clone());
                            expr_idx += 1;
                            new_expr
                        })
                        .collect();
                    MergeActionKind::NotMatchedInsert {
                        columns: columns.clone(),
                        values: new_values,
                    }
                }
            };

            new_actions.push(MergeAction {
                kind: new_kind,
                predicate,
            });
        }

        Ok(Self {
            table_name: self.table_name.clone(),
            table_schema: self.table_schema.clone(),
            source: inputs.swap_remove(0),
            on,
            actions: new_actions,
            schema: self.schema.clone(),
        })
    }
}
