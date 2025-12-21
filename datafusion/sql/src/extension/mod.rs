use datafusion_common::{DFSchemaRef, Result};
use datafusion_expr::logical_plan::UserDefinedLogicalNodeCore;
use datafusion_expr::{Expr, LogicalPlan};
use std::fmt;
use std::hash::{Hash, Hasher};

#[derive(PartialEq, Eq)]
pub struct MergeIntoExtension {
    // Input logical plan (typically a join of target and source tables)
    pub input: LogicalPlan,
    // Schema of the target table
    pub schema: DFSchemaRef,
}

impl fmt::Debug for MergeIntoExtension {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        self.fmt_for_explain(f)
    }
}

impl Hash for MergeIntoExtension {
    fn hash<H: Hasher>(&self, state: &mut H) {
        self.input.hash(state);
        // Schema is not hashed as it's derived from the plan structure
    }
}

impl PartialOrd for MergeIntoExtension {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        self.input.partial_cmp(&other.input)
    }
}

impl UserDefinedLogicalNodeCore for MergeIntoExtension {
    fn name(&self) -> &str {
        "MergeInto"
    }

    fn inputs(&self) -> Vec<&LogicalPlan> {
        vec![&self.input]
    }

    fn schema(&self) -> &DFSchemaRef {
        &self.schema
    }

    fn expressions(&self) -> Vec<Expr> {
        // MERGE doesn't have expressions at the top level
        // The actual merge conditions and updates are in the input plan
        vec![]
    }

    fn fmt_for_explain(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "MergeInto")
    }

    fn with_exprs_and_inputs(
        &self,
        exprs: Vec<Expr>,
        mut inputs: Vec<LogicalPlan>,
    ) -> Result<Self> {
        assert_eq!(inputs.len(), 1, "MergeInto must have exactly 1 input");
        assert_eq!(exprs.len(), 0, "MergeInto should have no expressions");

        Ok(Self {
            input: inputs.swap_remove(0),
            schema: self.schema.clone(),
        })
    }
}